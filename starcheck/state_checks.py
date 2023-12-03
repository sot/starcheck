import numpy as np
from cxotime import CxoTime

from astropy.table import Table, vstack
import astropy.units as u
from functools import lru_cache
import numpy as np

import kadi.commands as kadi_commands
import kadi.commands.states as kadi_states
from cxotime import CxoTime
from chandra_maneuver import duration
from Quaternion import Quat


@lru_cache
def make_man_table():
    """
    Calculate the time for range of manuever angles using Chandra.Maneuver
    duration.
    """
    durations = []
    q0 = Quat(equatorial=(0, 0, 0))

    # Use a range of angles that sample the curve pretty well by eye
    # The duration function is a little slow and not vectorized, so
    # this is sparse.
    angles = [0, 5, 10, 15, 20, 25, 35, 50, 100, 150, 180]
    for angle in angles:
        q1 = Quat(equatorial=(angle, 0, 0))
        durations.append(duration(q0, q1))

    return Table([durations, angles], names=["duration", "angle"])


def calc_pcad_states_nman_durations(states):
    """
    For each NPNT state in a monotonically increasing list of states,
    calculate the duration of time in NMAN before it
    and interpolate into the man_table to calculate the equivalent
    angle for this duration.
    """
    man_table = make_man_table()

    nman_durations = []
    single_nman_duration = 0
    for state in states:
        if state["pcad_mode"] == "NMAN":
            single_nman_duration += state["tstop"] - state["tstart"]
        if (state["pcad_mode"] == "NPNT") & (single_nman_duration > 0):
            nman_durations.append(
                {
                    "tstart": state["tstart"],
                    "nman_sum": single_nman_duration.copy(),
                    "angle": np.interp(
                        single_nman_duration, man_table["duration"], man_table["angle"]
                    ),
                }
            )
            # Reset the sum of NMM time to 0 on any NPNT state
            single_nman_duration = 0

        # If in a funny state, just add a large "maneuver time" of 20ks
        if state["pcad_mode"] not in ["NMAN", "NPNT"]:
            single_nman_duration += 20000

    return Table(nman_durations)


@lru_cache
def make_man_angles(backstop_file):
    """
    Calculate the sum of time in NMAN before each NPNT dwell and make a table
    of the NPNT start times, the sum of time in NMAN before each, and the
    maneuver-equivalent-angle for each NMAN sum time.

    :param: backstop file
    :returns: astropy Table with columns 'tstart', 'nman_sum', 'angle'
    """
    states = get_states(backstop_file, state_keys=["pcad_mode"])

    # If the states begin with NPNT we're done.  Otherwise, get some more states.
    # 10 days is more than enough: it doesn't matter.
    if states["pcad_mode"][0] != "NPNT":
        pre_states = kadi_states.get_states(
            start=CxoTime(states[0]["tstart"]) - 10 * u.day,
            stop=states[0]["tstart"],
            state_keys=["pcad_mode"],
            merge_identical=True,
        )
        states = vstack([pre_states, states])

    out = calc_pcad_states_nman_durations(states)
    return out


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

    idx = np.argmin(np.abs(man_angles["tstart"] - npnt_tstart))
    dt = man_angles["tstart"][idx] - npnt_tstart

    # For starcheck, if something went wrong, just
    # use a large (180) angle
    if np.abs(dt) > 100:
        return float(default_large_angle)

    # Otherwise index into the table to get the angle for this duration
    return float(man_angles["angle"][idx])


def get_states(backstop_file, state_keys=None):
    bs_cmds = kadi_commands.get_cmds_from_backstop(backstop_file)
    rltt = bs_cmds.get_rltt() or bs_cmds["date"][0]

    # Scheduled stop time is the end of propagation, either the explicit
    # time as a pseudo-command in the loads or the last backstop command time.
    sched_stop = bs_cmds.get_scheduled_stop_time() or bs_cmds["date"][-1]

    # Get the states for available commands.  This automatically gets continuity.
    return kadi_states.get_states(
        cmds=bs_cmds,
        start=rltt,
        stop=sched_stop,
        state_keys=state_keys,
        merge_identical=True,
    )


def ir_zone_ok(backstop_file, out=None):
    """
    Check that the high IR zone is all in NMM.

    :param backstop_file: backstop file
    :param out: optional output file name (for plain text report)
    :returns: True if high IR zone time is all in NMM, False otherwise
    """

    states = get_states(backstop_file, state_keys=["pcad_mode", "obsid"])
    bs_cmds = kadi_commands.get_cmds_from_backstop(backstop_file)

    perigee_cmds = bs_cmds[
        (bs_cmds["type"] == "ORBPOINT") & (bs_cmds["event_type"] == "EPERIGEE")
    ]

    all_ok = True
    out_text = ["IR ZONE CHECKING"]
    for perigee_time in perigee_cmds["time"]:
        # Current high ir zone is from 25 minutes before to 27 minutes after
        # These don't seem worth vars, but make sure to change in the text below
        # too when these are updated.
        ir_zone_start = perigee_time - 25 * 60
        ir_zone_stop = perigee_time + 27 * 60
        out_text.append(f"Checking perigee at {CxoTime(perigee_time).date}")
        out_text.append(
            f"  High IR Zone from (perigee - 25m) {CxoTime(ir_zone_start).date} "
            f"to (perigee + 27m) {CxoTime(ir_zone_stop).date}"
        )
        ok = (states["tstart"] <= ir_zone_stop) & (states["tstop"] >= ir_zone_start)
        for state in states[ok]:
            out_text.append(
                f"  state {state['datestart']} {state['datestop']} {state['pcad_mode']}"
            )
        if np.any(states["pcad_mode"][ok] != "NMAN"):
            all_ok = False

    if out is not None:
        with open(out, "w") as fh:
            fh.writelines("\n".join(out_text))

    return all_ok
