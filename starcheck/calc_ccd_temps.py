#!/usr/bin/env python

"""
========================
load_check
========================

This code generates backstop load review outputs for checking a Xija model.
"""

import sys
import os
import glob
import logging
from pprint import pformat
import time
import shutil
import numpy as np
import json
import yaml

# Matplotlib setup
# Use Agg backend for command-line (non-interactive) operation
import matplotlib
if __name__ == '__main__':
    matplotlib.use('Agg')
import matplotlib.pyplot as plt

import Ska.Matplotlib
from Ska.Matplotlib import cxctime2plotdate as cxc2pd
import Ska.DBI
import Ska.Numpy
import Ska.engarchive.fetch_sci as fetch
from Chandra.Time import DateTime
import Chandra.cmd_states as cmd_states
import xija

import lineid_plot
from starcheck.config import config as defaultconfig
from starcheck.config import configvars
from starcheck.version import version

MSID = dict(aca='AACCCDPT')
TASK_DATA = os.path.dirname(__file__)
TASK_NAME = 'calc_ccd_temps'
MSID_PLOT_NAME = dict(aca='ccd_temperature.png')
# the model is reasonable from around Jan-2011
MODEL_VALID_FROM = '2011:001:00:00:00.000'
logger = logging.getLogger(TASK_NAME)

plt.rc("axes", labelsize=10, titlesize=12)
plt.rc("xtick", labelsize=10)
plt.rc("ytick", labelsize=10)

try:
    VERSION = str(version)
except:
    VERSION = 'dev'


def get_options():
    import argparse
    parser = argparse.ArgumentParser(
        description="Get CCD temps from xija model for starcheck")
    parser.set_defaults()
    parser.add_argument("oflsdir",
                       help="Load products OFLS directory")
    parser.add_argument("--outdir",
                       default=defaultconfig['outdir'],
                       help="Output directory")
    parser.add_argument('--json-obsids', nargs="?", type=argparse.FileType('r'),
                        default=defaultconfig['json_obsids'],
                        help="JSON-ified starcheck Obsid objects, as file or stdin")
    parser.add_argument('--output-temps', nargs="?", type=argparse.FileType('w'),
                        default=defaultconfig['output_temps'],
                        help="output destination for temperature JSON, file or stdout")
    parser.add_argument("--model-spec",
                        help="xija ACA model specification file")
    parser.add_argument("--traceback",
                        default=defaultconfig['traceback'],
                        help='Enable tracebacks')
    parser.add_argument("--verbose",
                        type=int,
                        default=defaultconfig['verbose'],
                        help="Verbosity (0=quiet, 1=normal, 2=debug)")
    parser.add_argument("--pitch",
                        default=defaultconfig['pitch'],
                        type=float,
                        help="Starting pitch (deg)")
    parser.add_argument("--T-aca",
                        type=float,
                        help="Starting ACA CCD temperature (degC)")
    parser.add_argument("--version",
                        action='version',
                        version=VERSION)
    args = parser.parse_args()
    return args


def get_ccd_temps(config=dict()):
    """
    Using the cmds and cmd_states sybase databases, available telemetry, and
    the pitches determined from the planning products, calculate xija ACA model
    temperatures for the given week.

    Takes a dictionary of configuration options which match the arguments
    from get_options()
    """

    # for any unset configuration variables, use the defaults
    for entry in configvars:
        if entry not in config:
            config[entry] = defaultconfig[entry]

    if not os.path.exists(config['outdir']):
        os.mkdir(config['outdir'])

    config_logging(config['outdir'], config['verbose'])

    # Store info relevant to processing for use in outputs
    proc = dict(run_user=os.environ['USER'],
                run_time=time.ctime(),
                errors=[],
                )
    logger.info('##############################'
                '#######################################')
    logger.info('# %s run at %s by %s'
                % (TASK_NAME, proc['run_time'], proc['run_user']))
    logger.info('# {} version = {}'.format(TASK_NAME, VERSION))
    logger.info('###############################'
                '######################################\n')
    #logger.info('Options:\n%s\n' % pformat(config))
    # save spec file in out directory
    shutil.copy(config['model_spec'], config['outdir'])

    # the yaml subset of json is sufficient for the
    # JSON we have from the Perl code
    sc_obsids = yaml.load(config['json_obsids'])

    # Connect to database (NEED TO USE aca_read)
    logger.info('Connecting to database to get cmd_states')
    db = Ska.DBI.DBI(dbi='sybase', server='sybase', user='aca_read',
                     database='aca')

    tnow = DateTime().secs

    # Get tstart, tstop, commands from backstop file in opt.oflsdir
    bs_cmds = get_bs_cmds(config['oflsdir'])
    tstart = bs_cmds[0]['time']
    tstop = bs_cmds[-1]['time']
    proc.update(dict(datestart=DateTime(tstart).date,
                     datestop=DateTime(tstop).date))

    # Get temperature telemetry for 3 weeks prior to min(tstart, NOW)
    tlm = get_telem_values(min(tstart, tnow),
                           ['aacccdpt', 'aosares1'],
                           days=21,
                           name_map={'aosares1': 'pitch'})

    states = get_week_states(config, tstart, tstop, bs_cmds, tlm, db)

    if tstart >  DateTime(MODEL_VALID_FROM).secs:
        times, ccd_temp = make_week_predict(config, states, tstop)
    else:
        times, ccd_temp = mock_telem_predict(states)

    make_check_plots(config, states, times,
                     ccd_temp, tstart)

    intervals = get_obs_intervals(sc_obsids)
    obstemps = get_interval_temps(intervals, times, ccd_temp)
    #write_obstemps(config, obstemps)
    return json.dumps(obstemps, sort_keys=True, indent=4,
	                  cls=NumpyAwareJSONEncoder)


def get_interval_temps(intervals, times, ccd_temp):
    """
    Determine the max temperature over each interval.

    :param intervals: list of dictionaries describing obsid/catalog intervals
    :param times: times of the temperature samples
    :param ccd_temp: ccd temperature values

    :returns: dictionary (keyed by obsid) of intervals with max ccd_temps
    """
    obstemps = {}
    for interval in intervals:
        # treat the model samples as temperature intervals
        # and find the max during each obsid npnt interval
        tok = np.zeros(len(ccd_temp), dtype=bool)
        tok[:-1] = ((times[:-1] < interval['tstop'])
                    & (times[1:] > interval['tstart']))
        obsid = "{}".format(interval['obsid'])
        obs = dict(ccd_temp=np.max(ccd_temp[tok]))
        obs.update(interval)
        obstemps[obsid] = obs
    return obstemps


def get_obs_intervals(sc_obsids):
    """
    For the list of Obsid objects from starcheck, determine the interval of
    each star catalog (as in, for obsids with no following maneuver, the catalog
    will apply to an interval that spans that obsid and the next one)

    :param sc_obsids: starcheck Obsid list
    :returns: list of dictionaries containing obsid/tstart/tstop
    """
    intervals = []
    for idx in range(len(sc_obsids)):
        obs = sc_obsids[idx]
        interval = dict(
            obsid=obs['obsid'],
            tstart=obs['obs_tstart'],
            tstop=obs['obs_tstop'])
        if 'no_following_manvr' in obs:
            interval.update(dict(
                tstop=sc_obsids[idx + 1]['obs_tstop'],
                text='(max through following obsid)'))
        intervals.append(interval)
    return intervals


def calc_model(model_spec, states, start, stop, aacccdpt=None, aacccdpt_times=None):
    """
    Run the xija aca thermal model over the interval requested

    :param model_spec: aca model spec file
    :param states: generated command states spanning the interval from
                   last available telemetry through the planning week being
                   evaluated
    :param start: start time
    :param stop: stop time
    :param aacccdpt: an available aaaccdpt data sample
    :param aacccdpt_times: time of the given sample
    :returns: xija.Thermalmodel
    """

    model = xija.ThermalModel('aca', start=start, stop=stop,
                              model_spec=model_spec)
    times = np.array([states['tstart'], states['tstop']])
    model.comp['pitch'].set_data(states['pitch'], times)
    model.comp['eclipse'].set_data(False)
    model.comp['aca0'].set_data(aacccdpt, aacccdpt_times)
    model.comp['aacccdpt'].set_data(aacccdpt, aacccdpt_times)
    model.make()
    model.calc()
    return model


def get_week_states(opt, tstart, tstop, bs_cmds, tlm, db):
    """
    Make states from last available telemetry through the end of the backstop commands

    :param opt: options dictionary from get_options()
    :param tstart: start time from first backstop command
    :param tstop: stop time from last backstop command
    :param bs_cmds: backstop commands for products under review
    :param tlm: available pitch and aacccdpt telemetry recarray from fetch
    :param db: sybase database handle
    :returns: numpy recarray of states
    """

    # Try to make initial state0 from cmd line options
    state0 = dict((x, opt.get(x))
                  for x in ('pitch', 'T_aca'))
    state0.update({'tstart': tstart - 30,
                   'tstop': tstart,
                   'datestart': DateTime(tstart - 30).date,
                   'datestop': DateTime(tstart).date,
                   'q1': 0.0, 'q2': 0.0, 'q3': 0.0, 'q4': 1.0,
                   }
                  )

    # If cmd lines options were not fully specified then get state0 as last
    # cmd_state that starts within available telemetry.  Update with the
    # mean temperatures at the start of state0.
    if None in state0.values():
        state0 = cmd_states.get_state0(tlm['date'][-5], db,
                                       datepar='datestart')
        ok = ((tlm['date'] >= state0['tstart'] - 700) &
              (tlm['date'] <= state0['tstart'] + 700))
        state0.update({'aacccdpt': np.mean(tlm['aacccdpt'][ok])})

    logger.debug('state0 at %s is\n%s' % (DateTime(state0['tstart']).date,
                                          pformat(state0)))

    # Get commands after end of state0 through first backstop command time
    cmds_datestart = state0['datestop']
    cmds_datestop = bs_cmds[0]['date']

    # Get timeline load segments including state0 and beyond.
    timeline_loads = db.fetchall("""SELECT * from timeline_loads
                                 WHERE datestop > '%s'
                                 and datestart < '%s'"""
                                 % (cmds_datestart, cmds_datestop))
    logger.info('Found {} timeline_loads  after {}'.format(
            len(timeline_loads), cmds_datestart))

    # Get cmds since datestart within timeline_loads
    db_cmds = cmd_states.get_cmds(cmds_datestart, db=db, update_db=False,
                                  timeline_loads=timeline_loads)

    # Delete non-load cmds that are within the backstop time span
    # => Keep if timeline_id is not None or date < bs_cmds[0]['time']
    db_cmds = [x for x in db_cmds if (x['timeline_id'] is not None or
                                      x['time'] < bs_cmds[0]['time'])]

    logger.info('Got %d cmds from database between %s and %s' %
                  (len(db_cmds), cmds_datestart, cmds_datestop))

    # Get the commanded states from state0 through the end of backstop commands
    states = cmd_states.get_states(state0, db_cmds + bs_cmds)
    states[-1].datestop = bs_cmds[-1]['date']
    states[-1].tstop = bs_cmds[-1]['time']
    logger.info('Found %d commanded states from %s to %s' %
                 (len(states), states[0]['datestart'], states[-1]['datestop']))
    return states


def make_week_predict(opt, states, tstop):
    """
    Get model predictions over the desired states
    :param opt: options dictionary containing at least opt['model_spec']
    :param states: states from get_states()
    :param tstop: stop time for model calculation
    :returns: (times, temperature vals) as numpy arrays
    """

    state0 = states[0]

    # Create array of times at which to calculate ACA temps, then do it.
    logger.info('Calculating ACA thermal model')
    logger.info('Propagation initial time and ACA: {} {:.2f}'.format(
            DateTime(state0['tstart']).date, state0['aacccdpt']))

    model = calc_model(opt['model_spec'], states, state0['tstart'], tstop,
                       state0['aacccdpt'], state0['tstart'])

    return model.times, model.comp['aacccdpt'].mvals


def mock_telem_predict(states):
    """
    Fetch AACCCDPT telem over the interval of the given states and return values
    as if they had been calculated by the xija ThermalModel.

    :param states: states as generated from get_states
    :returns: (times, temperature vals) as numpy arrays
    """

    state0 = states[0]
    # Get temperature telemetry over the interval
    logger.info('Fetching telemetry between %s and %s' % (states[0]['tstart'],
                                                          states[-1]['tstop']))
    tlm = fetch.MSIDset(['aacccdpt'],
                        states[0]['tstart'],
                        states[-1]['tstop'],
                        stat='5min')
    temps = {'aca': tlm['aacccdpt'].vals}
    return tlm['aacccdpt'].times, tlm['aacccdpt'].vals



def get_bs_cmds(oflsdir):
    """Return commands for the backstop file in opt.oflsdir.
    """
    import Ska.ParseCM
    backstop_file = globfile(os.path.join(oflsdir, 'CR*.backstop'))
    logger.info('Using backstop file %s' % backstop_file)
    bs_cmds = Ska.ParseCM.read_backstop(backstop_file)
    logger.info('Found %d backstop commands between %s and %s' %
                  (len(bs_cmds), bs_cmds[0]['date'], bs_cmds[-1]['date']))

    return bs_cmds


def get_telem_values(tstart, msids, days=7, name_map={}):
    """
    Fetch last ``days`` of available ``msids`` telemetry values before
    time ``tstart``.

    :param tstart: start time for telemetry (secs)
    :param msids: fetch msids list
    :param days: length of telemetry request before ``tstart``
    :param dt: sample time (secs)
    :param name_map: dict mapping msid to recarray col name
    :returns: np recarray of requested telemetry values from fetch
    """
    tstart = DateTime(tstart).secs
    start = DateTime(tstart - days * 86400).date
    stop = DateTime(tstart).date
    logger.info('Fetching telemetry between %s and %s' % (start, stop))
    msidset = fetch.MSIDset(msids, start, stop, stat='5min')
    start = max(x.times[0] for x in msidset.values())
    stop = min(x.times[-1] for x in msidset.values())
    msidset.interpolate(328.0, start, stop + 1)  # 328 for '5min' stat

    # Finished when we found at least 4 good records (20 mins)
    if len(msidset.times) < 4:
        raise ValueError('Found no telemetry within %d days of %s'
                         % (days, str(tstart)))

    outnames = ['date'] + [name_map.get(x, x) for x in msids]
    vals = {name_map.get(x, x): msidset[x].vals for x in msids}
    vals['date'] = msidset.times
    out = Ska.Numpy.structured_array(vals, colnames=outnames)

    return out


def config_logging(outdir, verbose):
    """Set up file and console logger.
    See http://docs.python.org/library/logging.html
              #logging-to-multiple-destinations
    """
    # Disable auto-configuration of root logger by adding a null handler.
    # This prevents other modules (e.g. Chandra.cmd_states) from generating
    # a streamhandler by just calling logging.info(..).
    class NullHandler(logging.Handler):
        def emit(self, record):
            pass
    rootlogger = logging.getLogger()
    rootlogger.addHandler(NullHandler())

    loglevel = {0: logging.CRITICAL,
                1: logging.INFO,
                2: logging.DEBUG}.get(verbose, logging.INFO)

    logger = logging.getLogger(TASK_NAME)
    logger.setLevel(loglevel)

    formatter = logging.Formatter('%(message)s')

    console = logging.StreamHandler()
    console.setFormatter(formatter)
    logger.addHandler(console)

    filehandler = logging.FileHandler(
        filename=os.path.join(outdir, 'run.dat'), mode='w')
    filehandler.setFormatter(formatter)
    logger.addHandler(filehandler)


class NumpyAwareJSONEncoder(json.JSONEncoder):
    def default(self, obj):
        if hasattr(obj, 'tolist'):
            return obj.tolist()
        return json.JSONEncoder.default(self, obj)


def write_obstemps(opt, obstemps):
    """JSON write temperature predictions"""
    jfile = opt['output_temps']
    jfile.write(json.dumps(obstemps, sort_keys=True, indent=4,
                           cls=NumpyAwareJSONEncoder))
    jfile.flush()


def plot_two(fig_id, x, y, x2, y2,
             linestyle='-', linestyle2='-',
             color='blue', color2='magenta',
             ylim=None, ylim2=None,
             xlabel='', ylabel='', ylabel2='',
             figsize=(7, 3.5),
             ):
    """Plot two quantities with a date x-axis"""
    xt = Ska.Matplotlib.cxctime2plotdate(x)
    fig = plt.figure(fig_id, figsize=figsize)
    fig.clf()
    ax = fig.add_subplot(1, 1, 1)
    ax.plot_date(xt, y, fmt='-', linestyle=linestyle, color=color)
    ax.set_xlim(min(xt), max(xt))
    if ylim:
        ax.set_ylim(*ylim)
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.grid()

    ax2 = ax.twinx()

    xt2 = Ska.Matplotlib.cxctime2plotdate(x2)
    ax2.plot_date(xt2, y2, fmt='-', linestyle=linestyle2, color=color2)
    pad = 1
    ax2.set_xlim(min(xt) - pad, max(xt) + pad)
    if ylim2:
        ax2.set_ylim(*ylim2)
    ax2.set_ylabel(ylabel2, color=color2)
    ax2.xaxis.set_visible(False)

    Ska.Matplotlib.set_time_ticks(ax)
    [label.set_rotation(30) for label in ax.xaxis.get_ticklabels()]
    [label.set_color(color2) for label in ax2.yaxis.get_ticklabels()]

    return {'fig': fig, 'ax': ax, 'ax2': ax2}


def make_check_plots(opt, states, times, temps, tstart):
    """
    Make output plots.

    :param opt: options
    :param states: commanded states
    :param times: time stamps (sec) for temperature arrays
    :param temps: dict of temperatures
    :param tstart: load start time
    :rtype: dict of review information including plot file names
    """
    plots = {}

    # Start time of loads being reviewed expressed in units for plotdate()
    load_start = cxc2pd([tstart])[0]

    # Add labels for obsids
    id_xs = [cxc2pd([states[0]['tstart']])[0]]
    id_labels = [str(states[0]['obsid'])]
    for s0, s1 in zip(states[:-1], states[1:]):
        if s0['obsid'] != s1['obsid']:
            id_xs.append(cxc2pd([s1['tstart']])[0])
            id_labels.append(str(s1['obsid']))

    logger.info('Making temperature check plots')
    for fig_id, msid in enumerate(('aca',)):
        plots[msid] = plot_two(fig_id=fig_id + 1,
                               x=times,
                               y=temps,
                               x2=pointpair(states['tstart'], states['tstop']),
                               y2=pointpair(states['pitch']),
                               xlabel='Date',
                               ylabel='Temperature (C)',
                               ylabel2='Pitch (deg)',
                               ylim2=(40, 180),
                               figsize=(9, 5),
                               )
        ax = plots[msid]['ax']
        plt.subplots_adjust(bottom=0.1)
        pad = 1
        lineid_plot.plot_line_ids([cxc2pd([times[0]])[0] - pad, cxc2pd([times[-1]])[0] + pad],
                                  [ax.get_ylim()[0], ax.get_ylim()[0]],
                                  id_xs, id_labels, box_axes_space=0.12,
                                  ax=ax,
                                  label1_size=7)
        plt.tight_layout()
        plt.subplots_adjust(top=.85)
        plots[msid]['ax'].axvline(load_start, linestyle=':', color='g',
                                  linewidth=1.0)
        filename = MSID_PLOT_NAME[msid]
        outfile = os.path.join(opt['outdir'], filename)
        logger.info('Writing plot file %s' % outfile)
        plots[msid]['fig'].savefig(outfile)
        plots[msid]['filename'] = filename

    return plots


def get_states(datestart, datestop, db):
    """Get states exactly covering date range

    :param datestart: start date
    :param datestop: stop date
    :param db: database handle
    :returns: np recarry of states
    """
    datestart = DateTime(datestart).date
    datestop = DateTime(datestop).date
    logger.info('Getting commanded states between %s - %s' %
                 (datestart, datestop))

    # Get all states that intersect specified date range
    cmd = """SELECT * FROM cmd_states
             WHERE datestop > '%s' AND datestart < '%s'
             ORDER BY datestart""" % (datestart, datestop)
    logger.debug('Query command: %s' % cmd)
    states = db.fetchall(cmd)
    logger.info('Found %d commanded states' % len(states))

    # Set start and end state date/times to match telemetry span.  Extend the
    # state durations by a small amount because of a precision issue converting
    # to date and back to secs.  (The reference tstop could be just over the
    # 0.001 precision of date and thus cause an out-of-bounds error when
    # interpolating state values).
    states[0].tstart = DateTime(datestart).secs - 0.01
    states[0].datestart = DateTime(states[0].tstart).date
    states[-1].tstop = DateTime(datestop).secs + 0.01
    states[-1].datestop = DateTime(states[-1].tstop).date

    return states


def pointpair(x, y=None):
    if y is None:
        y = x
    return np.array([x, y]).reshape(-1, order='F')


def globfile(pathglob):
    """Return the one file name matching ``pathglob``.  Zero or multiple
    matches raises an IOError exception."""

    files = glob.glob(pathglob)
    if len(files) == 0:
        raise IOError('No files matching %s' % pathglob)
    elif len(files) > 1:
        raise IOError('Multiple files matching %s' % pathglob)
    else:
        return files[0]


if __name__ == '__main__':
    opt = get_options()
    try:
        get_ccd_temps(vars(opt))
    except Exception, msg:
        if opt.traceback:
            raise
        else:
            sys.stderr.write("ERROR:{}".format(msg))
            sys.exit(1)
