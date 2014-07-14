#!/usr/bin/env python
"""
Independent code to predict ACA CCD temperature stats during obsids

% ipython

>>> run -i validate_aca_temps.py --mpdir /data/mpcrit1/mplogs/2013/MAY0613/ofls

OR

>>> model, dwell_stats = calc_dwell_stats(start, stop)
"""

import argparse
import glob
import os

import numpy as np

import xija
from kadi import events
import chandra_models
from Ska.engarchive import fetch_sci as fetch
from Chandra.Time import DateTime


def get_opt(args=None):
    parser = argparse.ArgumentParser(description='Validate calc_ccd_temps')
    parser.add_argument('--mpdir',
                        default='/data/mpcrit1/mplogs/2014/FEB0314/oflsa',
                        type=str,
                        help='Mission planning directory')
    opt = parser.parse_args(args)
    return opt


def calc_ccd_model(start, stop):
    start = DateTime(start)
    stop = DateTime(stop)
    model_spec = chandra_models.get_xija_model_file('aca')

    # Initially propagate model for three days prior to estimate aca0 value
    model = xija.XijaModel('aca', model_spec=model_spec, start=start - 3, stop=stop)
    dat = fetch.Msid('aacccdpt', start - 3, start - 2, stat='5min')
    model.comp['aca0'].set_data(float(dat.vals[0]))
    model.make()
    model.calc()

    return model


def calc_dwell_stats(start, stop):
    model = calc_ccd_model(start, stop)

    manvrs = events.manvrs.filter(start, stop)
    dwells = [(manvr.npnt_start, manvr.npnt_stop) for manvr in manvrs]
    obsids = [manvr.get_obsid() for manvr in manvrs]
    dwell_stats = []
    for obsid, dwell in zip(obsids, dwells):
        i0, i1 = np.searchsorted(model.times, DateTime(dwell).secs)
        dwell_stat = {'obsid': obsid,
                      'start': dwell[0],
                      'stop': dwell[1],
                      'max_ccd_temp': np.max(model.comp['aacccdpt'].mvals[i0:i1 + 1]),
                      'min_ccd_temp': np.min(model.comp['aacccdpt'].mvals[i0:i1 + 1])}
        dwell_stats.append(dwell_stat)

    return model, dwell_stats


def plot_model_dwell_stats(model, dwell_stats):
    import matplotlib.pyplot as plt
    from Ska.Matplotlib import plot_cxctime

    plt.close(1)
    plt.figure(1)

    plot_cxctime(model.times, model.comp['aacccdpt'].dvals, '-b')
    plot_cxctime(model.times, model.comp['aacccdpt'].mvals, '-r')

    y0, y1 = plt.ylim()
    plt.vlines(DateTime([dwell['start'] for dwell in dwell_stats]).plotdate, y0, y1)
    plt.show()


def main(args=None):
    opt = get_opt(args)

    # Get start and stop from backstop (quick-n-dirty)
    backstop_file = glob.glob(os.path.join(opt.mpdir, '*.backstop'))[0]
    with open(backstop_file, 'r') as fh:
        lines = fh.readlines()
    start = lines[0].split()[0]
    stop = lines[-1].split()[0]

    model, dwell_stats = calc_dwell_stats(start, stop)

    return model, dwell_stats


if __name__ == '__main__':
    import pprint
    model, dwell_stats = main()
    pprint.pprint(dwell_stats)
    plot_model_dwell_stats(model, dwell_stats)
