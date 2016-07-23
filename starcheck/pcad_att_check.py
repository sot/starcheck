import re
import hopper
from parse_cm import read_backstop, read_maneuver_summary, read_or_list
from Chandra.Time import DateTime
from astropy.table import Table


def check_characteristics_date(ofls_characteristics_file, ref_date=None):
    match = re.search(r'CHARACTERIS_(\d\d)([A-Z]{3})(\d\d)', ofls_characteristics_file)
    if not match:
        return False

    day, mon, yr = match.groups()
    yr = int(yr)
    yr += 1900 if (yr > 90) else 2000
    mon = mon.lower().capitalize()
    file_date = DateTime('{}{}{} at 00:00:00.000'.format(yr, mon, day))

    return False if (DateTime(ref_date) - file_date > 30) else True


def test_check_characteristics_date():
    ok = check_characteristics_date('blah/blah/L_blah_CHARACTERIS_01OCT15',
                                    '2015Oct30 at 00:00:00.000')
    assert ok is True

    ok = check_characteristics_date('blah/blah/L_blah_CHARACTERIS_01OCT15',
                                    '2015Nov02 at 00:00:00.000')
    assert ok is False

    ok = check_characteristics_date('blah/blah/L_blah_CHARACTERIS_99OCT15',
                                    '1999Oct20 at 00:00:00.000')
    assert ok is True

    ok = check_characteristics_date('blah/blah/L_blah',
                                    '2015Nov02 at 00:00:00.000')
    assert ok is False


def recent_sim_history(time, file):
    """
    Read from the end of the a SIM history file and return the
    first (last) time and value before the given time.  Specific
    to SIM focus and transition history based on the regex for
    parsing and the int cast of the parsed data.
    """
    for line in reversed(open(file).readlines()):
        match = re.match('^(\d+\.\d+)\s+\|\s+(\S+)\s*$',
                         line)
        if match:
            greta_time, value = match.groups()
            if (DateTime(greta_time, format='greta').secs < time):
                return greta_time, int(value)


def make_pcad_attitude_check_report(backstop_file, or_list_file=None, mm_file=None,
                                    simtrans_file=None, simfocus_file=None,
                                    ofls_characteristics_file=None, out=None,
                                    dynamic_offsets_file=None,
                                    ):
    """
    Make a report for checking PCAD attitudes

    """
    all_ok = True
    lines = []  # output report lines

    mm = read_maneuver_summary(mm_file)
    q = [mm[0][key] for key in ['q1_0', 'q2_0', 'q3_0', 'q4_0']]
    bs = read_backstop(backstop_file)
    simfa_time, simfa = recent_sim_history(DateTime(bs[0]['date']).secs,
                                           simfocus_file)
    simpos_time, simpos = recent_sim_history(DateTime(bs[0]['date']).secs,
                                             simtrans_file)
    initial_state = {'q_att': q,
                     'simpos': simpos,
                     'simfa_pos': simfa}

    or_list = None if or_list_file is None else read_or_list(or_list_file)
    if or_list is None:
        lines.append('ERROR: No OR list provided, cannot check attitudes')
        all_ok = False

    # If dynamical offsets file is available then load was planned using
    # Matlab tools 2016:210 later, which implements the "Cycle 18 aimpoint
    # transition plan".  This code injects new OR list attributes for the
    # dynamical offset.
    if dynamic_offsets_file is not None and or_list is not None:
        ofls_characteristics_file = None
        lines.append('INFO: using dynamic offsets file {}'.format(dynamic_offsets_file))
        or_map = {or_['obsid']: or_ for or_ in or_list}

        doffs = Table.read(dynamic_offsets_file, format='ascii.basic', guess=False)
        for doff in doffs:
            obsid = doff['obsid']
            if obsid in or_map:
                or_map[obsid]['aca_offset_y'] = doff['aca_offset_y'] / 3600.
                or_map[obsid]['aca_offset_z'] = doff['aca_offset_z'] / 3600.

        # Check that obsids in OR list match those in dynamic offsets table
        obsid_mismatch = set(or_map) ^ set(doffs['obsid'])
        if obsid_mismatch:
            all_ok = False
            lines.append('WARNING: mismatch between OR-list and dynamic offsets table {}'
                         .format(obsid_mismatch))

    # Run the commands and populate attributes in `sc`, the spacecraft state.
    # In particular sc.checks is a dict of checks by obsid.
    # Any state value (e.g. obsid or q_att) has a corresponding plural that
    # gives the history of updates as a dict with a `value` and `date` key.
    sc = hopper.run_cmds(backstop_file, or_list, ofls_characteristics_file,
                         initial_state=initial_state)
    # Iterate through obsids in order
    obsids = [obj['value'] for obj in sc.obsids]
    for obsid in obsids:
        if obsid not in sc.checks:
            continue

        checks = sc.checks[obsid]
        for check in checks:
            if check['name'] == 'CheckObsreqTargetFromPcad':
                ok = check['ok']
                all_ok &= ok
                if check.get('skip'):
                    message = 'SKIPPED: {}'.format(check['message'])
                else:
                    message = 'OK' if ok else check['message']
                line = '{:5d}: {}'.format(obsid, message)
                lines.append(line)

    if out is not None:
        with open(out, 'w') as fh:
            fh.writelines("\n".join(lines))

    return all_ok
