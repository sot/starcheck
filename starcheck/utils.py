import os
import functools
import numpy as np

from Chandra.Time import DateTime
from Chandra.Time import secs2date as time2date, date2secs as pydate2secs
import starcheck
from starcheck.pcad_att_check import make_pcad_attitude_check_report, check_characteristics_date
from starcheck.calc_ccd_temps import get_ccd_temps
from starcheck.plot import make_plots_for_obsid
from starcheck.check_ir_zone import ir_zone_ok
from starcheck import __version__ as version
from kadi.commands import states
import proseco.characteristics as proseco_char


def print_traceback_on_exception(func):
    """Decorator to print a stack trace on exception.

    The default perl inline suppresses this stack trace which makes debugging
    difficult.
    """
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except Exception:
            import traceback
            traceback.print_exc()
            raise
    return wrapper


# Borrowed from https://stackoverflow.com/a/33160507
def de_bytestr(data):
    if isinstance(data, bytes):
        return data.decode()
    if isinstance(data, dict):
        return dict(map(de_bytestr, data.items()))
    if isinstance(data, tuple):
        return tuple(map(de_bytestr, data))
    if isinstance(data, list):
        return list(map(de_bytestr, data))
    if isinstance(data, set):
        return set(map(de_bytestr, data))
    return data


@print_traceback_on_exception
def date2time(date):
    return pydate2secs(de_bytestr(date))


@print_traceback_on_exception
def ccd_temp_wrapper(kwargs):
    return get_ccd_temps(**de_bytestr(kwargs))


@print_traceback_on_exception
def plot_cat_wrapper(kwargs):
    return make_plots_for_obsid(**de_bytestr(kwargs))


@print_traceback_on_exception
def starcheck_version():
    return version


@print_traceback_on_exception
def get_chandra_models_version():
    return proseco_char.chandra_models_version


@print_traceback_on_exception
def get_kadi_scenario():
    return os.getenv('KADI_SCENARIO', default="None")


@print_traceback_on_exception
def get_data_dir():
    sc_data = os.path.join(os.path.dirname(starcheck.__file__), 'data')
    return sc_data if os.path.exists(sc_data) else ""


@print_traceback_on_exception
def _make_pcad_attitude_check_report(kwargs):
    return make_pcad_attitude_check_report(**de_bytestr(kwargs))


@print_traceback_on_exception
def make_ir_check_report(kwargs):
    return ir_zone_ok(**de_bytestr(kwargs))


@print_traceback_on_exception
def get_dither_kadi_state(date):
    date = date.decode('ascii')
    cols = ['dither', 'dither_ampl_pitch', 'dither_ampl_yaw',
            'dither_period_pitch', 'dither_period_yaw']
    state = states.get_continuity(date, cols)
    # Cast the numpy floats as plain floats
    for key in ['dither_ampl_pitch', 'dither_ampl_yaw',
                'dither_period_pitch', 'dither_period_yaw']:
        state[key] = float(state[key])
    # get most recent change time
    state['time'] = float(np.max([DateTime(state['__dates__'][key]).secs for key in cols]))
    return state


@print_traceback_on_exception
def get_run_start_time(run_start_time, backstop_start):
    """
    Determine a reasonable reference run start time based on the supplied
    run start time and the time of the first backstop command.  This
    code uses a small hack so that a negative number is interpreted
    as the desired "days back" from the backstop start time.  All other
    Chandra.Time compatible formats for run start are used as absolute
    times (which will then be passed to the thermal model code as the
    time before which telemetry should be found for an initial state).
    Note that the logic to determine the initial state will not allow
    that state to be after backstop start time.

    :param run_start_time: supplied run start time in a Chandra.Time format,
                      empty string interpreted as "now" as expected,
                      negative numbers special cased to be interpreted as
                      "days back" relative to first backstop command.
    :param backstop_start: time of first backstop command
    :returns: YYYY:DOY string of reference run start time
    """

    run_start_time = de_bytestr(run_start_time)
    backstop_start = de_bytestr(backstop_start)

    # For the special case where run_start_time casts as a float
    # check to see if it is negative and if so, set the reference
    # time to be a time run_start_time days back from backstop start
    try:
        run_start_time = float(run_start_time)
    # Handle nominal errors if run_start_time None or non-float Chandra.Time OK string.
    except (TypeError, ValueError):
        ref_time = DateTime(run_start_time)
    else:
        if run_start_time < 0:
            ref_time = DateTime(backstop_start) + run_start_time
        else:
            raise ValueError("Float run_start_time should be negative")
    return ref_time.date
