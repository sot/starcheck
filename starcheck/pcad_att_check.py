import re
import hopper
from parse_cm import read_backstop, read_maneuver_summary
from Chandra.Time import DateTime


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

def recent_history(time, file):
    for state_line in reversed(open(file).readlines()):
        state_match = re.match('^(\d+\.\d+)\s+\|\s+(\S+)\s*$',
                                state_line)
        if state_match:
            if (DateTime(state_match.group(1), format='greta').secs
                < time):
                return state_match.group(1), int(state_match.group(2))


def make_pcad_attitude_check_report(backstop_file, or_list_file=None, mm_file=None,
                                    simtrans_file=None, simfocus_file=None,
                                    ofls_characteristics_file=None, out=None,
                                    ):
    """
    Make a report for checking PCAD attitudes

    """
    mm = read_maneuver_summary(mm_file)
    q = [mm[0][key] for key in ['q1_0', 'q2_0', 'q3_0', 'q4_0']]
    bs = read_backstop(backstop_file)
    simfa_time, simfa = recent_history(DateTime(bs[0]['date']).secs,
                                       simfocus_file)
    simpos_time, simpos = recent_history(DateTime(bs[0]['date']).secs,
                                       simtrans_file)
    initial_state = {'q_att': q,
                     'simpos': simpos,
                     'simfa_pos': simfa}
    # Run the commands and populate attributes in `sc`, the spacecraft state.
    # In particular sc.checks is a dict of checks by obsid.
    # Any state value (e.g. obsid or q_att) has a corresponding plural that
    # gives the history of updates as a dict with a `value` and `date` key.
    sc = hopper.run_cmds(backstop_file, or_list_file, ofls_characteristics_file,
                         initial_state=initial_state)
    all_ok = True

    # Iterate through obsids in order
    lines = []
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
       report = open(out, 'w')
       report.writelines("\n".join(lines))

    return all_ok
