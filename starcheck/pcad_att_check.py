# Licensed under a 3-clause BSD style license - see LICENSE.rst
import re
from astropy.table import Table
import Quaternion

from parse_cm import read_backstop, read_maneuver_summary, read_or_list
from Chandra.Time import DateTime
import hopper


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
    q = Quaternion.normalize([mm[0][key] for key in ['q1_0', 'q2_0', 'q3_0', 'q4_0']])
    bs = read_backstop(backstop_file)
    simfa_time, simfa = recent_sim_history(DateTime(bs[0]['date']).secs,
                                           simfocus_file)
    simpos_time, simpos = recent_sim_history(DateTime(bs[0]['date']).secs,
                                             simtrans_file)

    initial_state = {'q1': q[0],
                     'q2': q[1],
                     'q3': q[2],
                     'q4': q[3],
                     'simpos': simpos,
                     'simfa_pos': simfa}

    or_list = None if or_list_file is None else read_or_list(or_list_file)
    if or_list is None:
        lines.append('ERROR: No OR list provided, cannot check attitudes')
        all_ok = False

    # If dynamical offsets file is available then load was planned using
    # Matlab tools 2016_210 later, which implements the "Cycle 18 aimpoint
    # transition plan".  This code injects new OR list attributes for the
    # dynamical offset.
    if dynamic_offsets_file is not None and or_list is not None:
        # Existing OFLS characteristics file is not relevant for post 2016_210.
        # Products are planned using the Matlab tools SI align which matches the
        # baseline mission align matrix from pre-November 2015.
        ofls_characteristics_file = None

        lines.append('INFO: using dynamic offsets file {}'.format(dynamic_offsets_file))
        or_map = {or_['obsid']: or_ for or_ in or_list}

        doffs = Table.read(dynamic_offsets_file, format='ascii.basic', guess=False)
        for doff in doffs:
            obsid = doff['obsid']
            if obsid in or_map:
                or_map[obsid]['aca_offset_y'] = doff['aca_offset_y'] / 3600.
                or_map[obsid]['aca_offset_z'] = doff['aca_offset_z'] / 3600.

        # Check that obsids in dynamic offsets table are all in OR list
        if not set(doffs['obsid']).issubset(set(or_map)):
            all_ok = False
            obsid_mismatch = set(doffs['obsid']) - set(or_map)
            lines.append('WARNING: Obsid in dynamic offsets table but missing in OR list {}'
                         .format(list(obsid_mismatch)))

    # Run the commands and populate attributes in `sc`, the spacecraft state.
    # In particular sc.checks is a dict of checks by obsid.
    # Any state value (e.g. obsid or q_att) has a corresponding plural that
    # gives the history of updates as a dict with a `value` and `date` key.
    sc = hopper.run_cmds(backstop_file, or_list, ofls_characteristics_file,
                         initial_state=initial_state)
    # Iterate through checks by obsid to print status
    checks = sc.get_checks_by_obsid()
    for obsid in sc.obsids:
        for check in checks[obsid]:
            if check.name == 'attitude_consistent_with_obsreq':
                ok = check.success
                all_ok &= ok
                if check.not_applicable:
                    message = 'SKIPPED: {}'.format(":".join(check.infos))
                else:
                    message = 'OK' if ok else "ERROR: {}".format(":".join(check.errors))
                    line = '{:5d}: {}'.format(obsid, message)
                lines.append(line)

    if out is not None:
        with open(out, 'w') as fh:
            fh.writelines("\n".join(lines))

    return all_ok
