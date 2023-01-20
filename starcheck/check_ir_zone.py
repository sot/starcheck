from astropy.table import Table, vstack
from functools import lru_cache
import numpy as np

import kadi.commands as kadi_commands
import kadi.commands.states as kadi_states
from cxotime import CxoTime
from Chandra.Maneuver import duration
from Quaternion import Quat


@lru_cache
def make_man_table():
    """
    Calculate the time for range of manuever angles using Chandra.Maneuver
    duration.
    """
    angles = []
    durations = []
    q0 = Quat(equatorial=(0, 0, 0))
    for angle in np.arange(180):
        q1 = Quat(equatorial=(angle, 0, 0))
        angles.append(angle)
        durations.append(duration(q0, q1))
    return Table([durations, angles], names=['duration', 'angle'])


@lru_cache
def make_man_angles(backstop_file):
    """
    Calculate the sum of time in NMAN before each NPNT dwell and make a table
    of the NPNT start times, the sum of time in NMAN before each, and the
    maneuver-equivalent-angle for each NMAN sum time.

    :param: backstop file
    :returns: astropy time with columns 'tstart', 'nman_sum', 'angle'
    """

    man_table = make_man_table()
    states = get_states(backstop_file, state_keys=['pcad_mode'])

    # If the states begin with NPNT we're done.  Otherwise, get some more states.
    # 10 days is more than enough: it doesn't matter.
    if states['pcad_mode'][0] != 'NPNT':
        pre_states = kadi_states.get_states(
            start=CxoTime(states[0]['tstart']) - 10, stop=states[0]['tstart'],
            state_keys=['pcad_mode'], merge_identical=True)
        states = vstack([pre_states, states])

    # For each NPNT start, calculate the sum of time in NMAN before it
    # and interpolate into the man_table to calculate the equivalent
    # angle for a duration.
    nman_sums = []
    single_nman_sum = 0
    for state in states:
        if state['pcad_mode'] == 'NMAN':
            single_nman_sum += state['tstop'] - state['tstart']
        if (state['pcad_mode'] == 'NPNT') & (single_nman_sum > 0):
            nman_sums.append({'tstart': state['tstart'],
                              'nman_sum': single_nman_sum.copy(),
                              'angle': np.interp(single_nman_sum,
                                                 man_table['duration'],
                                                 man_table['angle'])})
            single_nman_sum = 0

        # If in a funny state, just add a large "maneuver" of 20ks
        if state['pcad_mode'] not in ['NMAN', 'NPNT']:
            single_nman_sum += 20000

    return Table(nman_sums)


def get_obs_man_angle(npnt_tstart, backstop_file, default_large_angle=180):
    """
    For the dwell that starts at npnt_tstart, get the maneuver-equivalent-angle
    the corresponds to the NMAN time before the dwell start.

    :param npnt_start: start time of npnt dwell
    :param backstop_file: backstop file
    :param default_large_angle: for weird cases, define the
         maneuver-equivalent-angle to be this value (default 180 deg)
    :returns: float value of a maneuver angle between 0 and 180
    """

    man_angles = make_man_angles(backstop_file)

    idx = np.argmin(np.abs(man_angles['tstart'] - npnt_tstart))
    dt = man_angles['tstart'][idx] - npnt_tstart

    # For starcheck, if something went wrong, just
    # use a large (180) angle
    if np.abs(dt) > 100:
        return float(default_large_angle)

    # Otherwise index into the table to get the angle for this duration
    return float(man_angles['angle'][idx])


def get_states(backstop_file, state_keys=None):

    bs_cmds = kadi_commands.get_cmds_from_backstop(backstop_file)
    bs_dates = bs_cmds['date']
    ok = bs_cmds['event_type'] == 'RUNNING_LOAD_TERMINATION_TIME'
    rltt = CxoTime(bs_dates[ok][0] if np.any(ok) else bs_dates[0])

    # Scheduled stop time is the end of propagation, either the explicit
    # time as a pseudo-command in the loads or the last backstop command time.
    ok = bs_cmds['event_type'] == 'SCHEDULED_STOP_TIME'
    sched_stop = CxoTime(bs_dates[ok][0] if np.any(ok) else bs_dates[-1])

    # Get the states for available commands.  This automatically gets continuity.
    return kadi_states.get_states(cmds=bs_cmds, start=rltt, stop=sched_stop,
                                  state_keys=['pcad_mode'], merge_identical=True)


def ir_zone_ok(backstop_file, out=None, pad_minutes=30):

    pad_seconds = pad_minutes * 60

    bs_cmds = kadi_commands.get_cmds_from_backstop(backstop_file)
    bs_dates = bs_cmds['date']
    ok = bs_cmds['event_type'] == 'RUNNING_LOAD_TERMINATION_TIME'
    rltt = CxoTime(bs_dates[ok][0] if np.any(ok) else bs_dates[0])

    # Scheduled stop time is the end of propagation, either the explicit
    # time as a pseudo-command in the loads or the last backstop command time.
    ok = bs_cmds['event_type'] == 'SCHEDULED_STOP_TIME'
    sched_stop = CxoTime(bs_dates[ok][0] if np.any(ok) else bs_dates[-1])

    # Get the states for available commands.  This automatically gets continuity.
    state_keys = ['pcad_mode', 'obsid']
    states = kadi_commands.states.get_states(cmds=bs_cmds, start=rltt, stop=sched_stop,
                                             state_keys=state_keys, merge_identical=True)

    perigee_cmds = bs_cmds[(bs_cmds['type'] == 'ORBPOINT')
                           & (bs_cmds['event_type'] == 'EPERIGEE')]

    all_ok = True
    out_text = ["IR ZONE CHECKING"]
    for perigee_time in perigee_cmds['time']:
        ir_zone_start = perigee_time - pad_seconds
        ir_zone_stop = perigee_time
        out_text.append(
            f"Checking perigee at {CxoTime(perigee_time).date}")
        out_text.append(
            f"  High IR Zone from {CxoTime(ir_zone_start).date} to {CxoTime(ir_zone_stop).date}")
        ok = (states['tstart'] <= ir_zone_stop) & (states['tstop'] >= ir_zone_start)
        for state in states[ok]:
            out_text.append(
                f"  state {state['datestart']} {state['datestop']} {state['pcad_mode']}")
        if np.any(states[ok]['pcad_mode'] != 'NMAN'):
            all_ok = False

    if out is not None:
        with open(out, 'w') as fh:
            fh.writelines("\n".join(out_text))

    return all_ok
