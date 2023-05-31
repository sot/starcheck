# Licensed under a 3-clause BSD style license - see LICENSE.rst
import re
from astropy.table import Table
import Quaternion
from Quaternion import Quat

from parse_cm import read_backstop, read_or_list
from Chandra.Time import DateTime
from agasc import sphere_dist
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


def recent_attitude_history(time, file):
    """
    Read from the end of the a ATTITUDE history file and return the
    first (last) time and value before the given time.  Specific
    to ATTITUDE and transition history based on the regex for
    parsing.
    """
    for line in reversed(open(file).readlines()):
        match = re.match('^(\d+\.\d+)\s+\|\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*', line)
        if match:
            greta_time, q1, q2, q3, q4 = match.groups()
            if (DateTime(greta_time, format='greta').secs < time):
                return greta_time, float(q1), float(q2), float(q3), float(q4)


def get_maneuvers(backstop_file, attitude_file=None):
    """
    Use the hopper state machine to make a maneuver structure from initial
    conditions and the backstop file.

    This duplicates some of make_pcad_attitude_check_report.

    :param backstop_file: backstop file
    :param attitude_file: attitude history file
    :returns: list of maneuvers
    """

    bs = read_backstop(backstop_file)

    # Get initial state attitude and sim position from history
    att_time, q1, q2, q3, q4 = recent_attitude_history(
        DateTime(bs[0]['date']).secs,
        attitude_file)
    q = Quaternion.normalize([q1, q2, q3, q4])

    initial_state = {'q1': q[0],
                     'q2': q[1],
                     'q3': q[2],
                     'q4': q[3]}

    sc = hopper.run_cmds(backstop_file, or_list=None, ofls_characteristics_file=None,
                         initial_state=initial_state, starcheck=True)

    mm = []
    for m in sc.maneuvers:
        q1 = Quaternion.normalize([m['initial']['q1'],
                                    m['initial']['q2'],
                                    m['initial']['q3'],
                                    m['initial']['q4']])
        q1 = Quat(q=q1)
        q2 = Quaternion.normalize([m['final']['q1'],
                                  m['final']['q2'],
                                  m['final']['q3'],
                                  m['final']['q4']])
        q2 = Quat(q=q2)
        angle = sphere_dist(q1.ra, q1.dec, q2.ra, q2.dec)

        # Re-arrange the hopper maneuever structure to match the structure previously used
        # from Parse_CM_File.pm
        man = {'initial_obsid': m['initial']['obsid'],
              'final_obsid': m['final']['obsid'],
              'start_date': m['initial']['date'],
              'stop_date': m['final']['date'],
              'ra': q2.ra,
              'dec': q2.dec,
              'roll': q2.roll,
              'dur': m['dur'],
              'angle': angle,
              'q1': m['final']['q1'],
              'q2': m['final']['q2'],
              'q3': m['final']['q3'],
              'q4': m['final']['q4'],
             'tstart': DateTime(m['initial']['date']).secs,
             'tstop': DateTime(m['final']['date']).secs,
             }
        mm.append(man)

    return mm


def make_pcad_attitude_check_report(backstop_file, or_list_file=None, attitude_file=None,
                                    simtrans_file=None, simfocus_file=None,
                                    ofls_characteristics_file=None, out=None,
                                    dynamic_offsets_file=None,
                                    ):
    """
    Make a report for checking PCAD attitudes

    """
    all_ok = True
    lines = []  # output report lines

    bs = read_backstop(backstop_file)

    # Get initial state attitude and sim position from history
    att_time, q1, q2, q3, q4 = recent_attitude_history(DateTime(bs[0]['date']).secs,
                                            attitude_file)
    q = Quaternion.normalize([q1, q2, q3, q4])
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
                         initial_state=initial_state, starcheck=True)
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
