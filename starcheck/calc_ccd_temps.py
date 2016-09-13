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
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches

from astropy.table import vstack, Table
import Ska.Matplotlib
from Ska.Matplotlib import cxctime2plotdate as cxc2pd
from Ska.Matplotlib import lineid_plot
import Ska.DBI
import Ska.Numpy
import Ska.engarchive.fetch_sci as fetch
from Chandra.Time import DateTime
import Chandra.cmd_states as cmd_states
from Chandra.cmd_states import get_cmd_states
import xija
from mica.archive.aca_dark import dark_model
from parse_cm import read_or_list
from chandra_aca.drift import get_aca_offsets

from starcheck.version import version

MSID = {'aca': 'AACCCDPT'}
TASK_DATA = os.path.dirname(__file__)
TASK_NAME = 'calc_ccd_temps'
MSID_PLOT_NAME = {'aca': 'ccd_temperature.png'}
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
                        default='out',
                        help="Output directory")
    parser.add_argument('--json-obsids', nargs="?", type=argparse.FileType('r'),
                        default=sys.stdin,
                        help="JSON-ified starcheck Obsid objects, as file or stdin")
    parser.add_argument('--output-temps', nargs="?", type=argparse.FileType('w'),
                        default=sys.stdout,
                        help="output destination for temperature JSON, file or stdout")
    parser.add_argument("--model-spec",
                        help="xija ACA model specification file")
    parser.add_argument("--char-file",
                        help="starcheck characteristics file")
    parser.add_argument("--orlist",
                        help="OR list")
    parser.add_argument("--traceback",
                        default=True,
                        help='Enable tracebacks')
    parser.add_argument("--verbose",
                        type=int,
                        default=1,
                        help="Verbosity (0=quiet, 1=normal, 2=debug)")
    parser.add_argument("--version",
                        action='version',
                        version=VERSION)
    args = parser.parse_args()
    return args


def get_ccd_temps(oflsdir, outdir='out',
                  json_obsids=sys.stdin,
                  model_spec=None, char_file=None, orlist=None,
                  verbose=1, **kwargs):
    """
    Using the cmds and cmd_states sybase databases, available telemetry, and
    the pitches determined from the planning products, calculate xija ACA model
    temperatures for the given week.

    :param oflsdir: products directory
    :param outdir: output directory for plots
    :param json_obsids: file-like object or string containing JSON of
                        starcheck Obsid objects
    :param model_spec: xija ACA model specification
    :param verbose: Verbosity (0=quiet, 1=normal, 2=debug)
    :returns: JSON dictionary of labeled dwell intervals with max temperatures
    """
    if not os.path.exists(outdir):
        os.mkdir(outdir)

    config_logging(outdir, verbose)

    # Store info relevant to processing for use in outputs
    proc = {'run_user': os.environ['USER'],
            'run_time': time.ctime(),
            'errors': []}
    logger.info('##############################'
                '#######################################')
    logger.info('# %s run at %s by %s'
                % (TASK_NAME, proc['run_time'], proc['run_user']))
    logger.info('# {} version = {}'.format(TASK_NAME, VERSION))
    logger.info('###############################'
                '######################################\n')

    # load more general starcheck characteristics to get red/yellow limits
    char = yaml.load(open(char_file))

    # save spec file in out directory
    shutil.copy(model_spec, outdir)

    # json_obsids can be either a string or a file-like object.  Try those options in order.
    try:
        sc_obsids = json.loads(json_obsids)
    except TypeError:
        sc_obsids = json.load(json_obsids)

    tnow = DateTime().secs

    # Get tstart, tstop, commands from backstop file in opt.oflsdir
    bs_cmds = get_bs_cmds(oflsdir)
    tstart = bs_cmds[0]['time']
    tstop = bs_cmds[-1]['time']
    proc['datestart'] = DateTime(tstart).date
    proc['datestop'] = DateTime(tstop).date

    # Get temperature telemetry for 30 days prior to min(tstart, NOW)
    tlm = get_telem_values(min(tstart, tnow),
                           ['aacccdpt', 'pitch'],
                           days=30)

    states = get_week_states(tstart, tstop, bs_cmds, tlm)
    # if the last obsid interval extends over the end of states
    # extend the state / predictions
    if ((states[-1]['obsid'] == sc_obsids[-1]['obsid'])
        & (sc_obsids[-1]['obs_tstop'] > states[-1]['tstop'])):
        tstop = sc_obsids[-1]['obs_tstop']
        states[-1]['tstop'] = sc_obsids[-1]['obs_tstop']
        states[-1]['datestop'] = DateTime(sc_obsids[-1]['obs_tstop']).date

    if tstart >  DateTime(MODEL_VALID_FROM).secs:
        times, ccd_temp = make_week_predict(model_spec, states, tstop)
    else:
        times, ccd_temp = mock_telem_predict(states)

    make_check_plots(outdir, states, times,
                     ccd_temp, tstart, tstop, char=char)
    intervals = get_obs_intervals(sc_obsids)
    obsreqs = None
    if orlist is not None:
        obsreqs = dict([(o['obsid'], o) for o in read_or_list(orlist)])
    obstemps = get_interval_data(intervals, times, ccd_temp, obsreqs)
    return json.dumps(obstemps, sort_keys=True, indent=4,
	                  cls=NumpyAwareJSONEncoder)


def get_interval_data(intervals, times, ccd_temp, obsreqs=None):
    """
    Determine the max temperature and mean offsets over each interval.

    :param intervals: list of dictionaries describing obsid/catalog intervals
    :param times: times of the temperature samples
    :param ccd_temp: ccd temperature values

    :returns: dictionary (keyed by obsid) of intervals with max ccd_temps
    """
    obstemps = {}
    for interval in intervals:
        # treat the model samples as temperature intervals
        # and find the max during each obsid npnt interval
        obs = {'ccd_temp': None}
        obs.update(interval)
        stop_idx = 1 + np.searchsorted(times, interval['tstop'])
        start_idx = -1 + np.searchsorted(times, interval['tstart'])
        ok_temps = ccd_temp[start_idx:stop_idx]
        ok_times = times[start_idx:stop_idx]
        if len(ok_temps) > 0:
            obs['ccd_temp'] = np.max(ok_temps)
            obs['n100_warm_frac'] = dark_model.get_warm_fracs(
                100, interval['tstart'], np.max(ok_temps))
        if obsreqs is None:
            obsreqs = {}
        if interval['obsid'] in obsreqs and len(ok_temps) > 0:
            obsreq = obsreqs[interval['obsid']]
            if 'chip_id' in obsreq:
                ddy, ddz = get_aca_offsets(obsreq['detector'],
                                           obsreq['chip_id'],
                                           obsreq['chipx'],
                                           obsreq['chipy'],
                                           time=ok_times,
                                           t_ccd=ok_temps)
                obs['aca_offset_y'] = np.mean(ddy)
                obs['aca_offset_z'] = np.mean(ddz)
        obstemps[str(interval['obsid'])] = obs
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
    for idx, obs in enumerate(sc_obsids):
        # if the range is undefined, just don't make
        # an entry / interval for the obsid
        if (('obs_tstart' not in obs)
            or 'obs_tstop' not in obs):
            continue
        interval = {'obsid': obs['obsid'],
                    'tstart': obs['obs_tstart'],
                    'tstop': obs['obs_tstop']}
        if 'no_following_manvr' in obs:
            interval['tstop'] = sc_obsids[idx + 1]['obs_tstop']
            interval['text'] = '(max through following obsid)'
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


def get_week_states(tstart, tstop, bs_cmds, tlm):
    """
    Make states from last available telemetry through the end of the backstop commands

    :param tstart: start time from first backstop command
    :param tstop: stop time from last backstop command
    :param bs_cmds: backstop commands for products under review
    :param tlm: available pitch and aacccdpt telemetry recarray from fetch
    :returns: numpy recarray of states
    """
    cstates = Table(get_cmd_states.fetch_states(DateTime(tstart) - 30,
                                                tstop,
                                                vals=['obsid',
                                                      'pitch',
                                                      'q1', 'q2', 'q3', 'q4']))
    # Get the last state at least 3 days before tstart and at least one hour
    # before the last available telemetry
    cstate0 = cstates[(cstates['tstart'] < (DateTime(tstart) - 3).secs)
                      & (cstates['tstart'] < (tlm[-1]['date'] - 3600))][-1]
    # get temperature data in a range around that initial state
    ok = ((tlm['date'] >= cstate0['tstart'] - 700) &
          (tlm['date'] <= cstate0['tstart'] + 700))
    init_aacccdpt = np.mean(tlm['aacccdpt'][ok])

    pre_bs_states = cstates[(cstates['tstart'] >= cstate0['tstart'])
                            & (cstates['tstart'] < tstart)]
    # cmd_states.get_states needs an initial state dictionary, so
    # construct one from the last pre-backstop state
    last_pre_bs_state = {col: pre_bs_states[-1][col]
                         for col in pre_bs_states[-1].colnames}
    # Get the commanded states from last cmd_state through the end of backstop commands
    states = Table(cmd_states.get_states(last_pre_bs_state, bs_cmds))
    states[-1]['datestop'] = bs_cmds[-1]['date']
    states[-1]['tstop'] = bs_cmds[-1]['time']
    # Truncate the last pre_bs_state at the new states start
    pre_bs_states[-1]['datestop'] = states[0]['datestart']
    pre_bs_states[-1]['tstop'] = states[0]['tstart']
    logger.info('Constructed %d commanded states from %s to %s' %
                (len(states), states[0]['datestart'], states[-1]['datestop']))
    # Combine the pre-backstop states with the commanded states
    all_states = vstack([pre_bs_states, states])
    # Add a column for temperature and pre-fill all to be the initial temperature
    # (the first state temperature is the only one used anyway)
    all_states['aacccdpt'] = init_aacccdpt
    return all_states


def make_week_predict(model_spec, states, tstop):
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

    model = calc_model(model_spec, states, state0['tstart'], tstop,
                       state0['aacccdpt'], state0['tstart'])

    return model.times, model.comp['aacccdpt'].mvals


def mock_telem_predict(states):
    """
    Fetch AACCCDPT telem over the interval of the given states and return values
    as if they had been calculated by the xija ThermalModel.

    :param states: states as generated from get_states
    :returns: (times, temperature vals) as numpy arrays
    """

    # Get temperature telemetry over the interval
    # Use the last state tstart instead of tstop because the last state
    # from cmd_states is extended to 2099
    logger.info('Fetching telemetry between %s and %s' % (states[0]['tstart'],
                                                          states[-1]['tstart']))

    tlm = fetch.MSIDset(['aacccdpt'],
                        states[0]['tstart'],
                        states[-1]['tstart'],
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


def write_obstemps(output_dev, obstemps):
    """JSON write temperature predictions"""
    jfile = output_dev
    jfile.write(json_obstemps)
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


def make_check_plots(outdir, states, times, temps, tstart, tstop, char):
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
    load_stop = cxc2pd([tstop])[0]

    # Add labels for obsids
    id_xs = [cxc2pd([states[0]['tstart']])[0]]
    id_labels = [str(states[0]['obsid'])]
    for s0, s1 in zip(states[:-1], states[1:]):
        if s0['obsid'] != s1['obsid']:
            id_xs.append(cxc2pd([s1['tstart']])[0])
            id_labels.append(str(s1['obsid']))

    logger.info('Making temperature check plots')
    for fig_id, msid in enumerate(('aca',)):
        temp_ymax = max(char['ccd_temp_red_limit'], np.max(temps))
        temp_ymin = min(char['ccd_temp_yellow_limit'], np.min(temps))
        plots[msid] = plot_two(fig_id=fig_id + 1,
                               x=times,
                               y=temps,
                               x2=pointpair(states['tstart'], states['tstop']),
                               y2=pointpair(states['pitch']),
                               xlabel='Date',
                               ylabel='Temperature (C)',
                               ylabel2='Pitch (deg)',
                               ylim=(temp_ymin - .05 * (temp_ymax - temp_ymin),
                                     temp_ymax + .05 * (temp_ymax - temp_ymin)),
                               ylim2=(40, 180),
                               figsize=(9, 5),
                               )
        ax = plots[msid]['ax']
        plots[msid]['ax'].axhline(y=char['ccd_temp_yellow_limit'],
                                  linestyle='--', color='g', linewidth=2.0)
        plots[msid]['ax'].axhline(y=char['ccd_temp_red_limit'],
                                  linestyle='--', color='r', linewidth=2.0)
        plt.subplots_adjust(bottom=0.1)
        pad = 1
        lineid_plot.plot_line_ids([cxc2pd([times[0]])[0] - pad, cxc2pd([times[-1]])[0] + pad],
                                  [ax.get_ylim()[0], ax.get_ylim()[0]],
                                  id_xs, id_labels, box_axes_space=0.12,
                                  ax=ax,
                                  label1_size=7)
        plt.tight_layout()
        plt.subplots_adjust(top=.85)

        xlims = ax.get_xlim()
        ylims = ax.get_ylim()
        pre_rect = matplotlib.patches.Rectangle((xlims[0], ylims[0]),
                                                load_start - xlims[0],
                                                ylims[1] - ylims[0],
                                                alpha=.1,
                                                facecolor='black',
                                                edgecolor='none')
        ax.add_patch(pre_rect)
        post_rect = matplotlib.patches.Rectangle((load_stop, ylims[0]),
                                                 xlims[-1] - load_stop,
                                                 ylims[1] - ylims[0],
                                                 alpha=.1,
                                                 facecolor='black',
                                                 edgecolor='none')
        ax.add_patch(post_rect)

        filename = MSID_PLOT_NAME[msid]
        outfile = os.path.join(outdir, filename)
        logger.info('Writing plot file %s' % outfile)
        plots[msid]['fig'].savefig(outfile)
        plots[msid]['filename'] = filename

    return plots


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
        json_obstemps = get_ccd_temps(**vars(opt))
        write_obstemps(opt.output_temps, json_obstemps)
    except Exception, msg:
        if opt.traceback:
            raise
        else:
            sys.stderr.write("ERROR:{}".format(msg))
            sys.exit(1)
