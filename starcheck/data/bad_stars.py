# Licensed under a 3-clause BSD style license - see LICENSE.rst
from __future__ import division
import os
import numpy as np
import re
import pickle
import Ska.DBI
from Chandra.Time import DateTime
from astropy.table import Table, join

import bad_obsids

dbh = Ska.DBI.DBI(dbi='sybase', user='aca_read')
agasc_bad = open('manual_bad_stars').read()


def sausage_list(gui, bad_acq, file='test_agasc.bad',
                 gui_n=3, gui_med=.50, acq_n=6, acq_fail=.80):

    # exclude bad gui obsids "in place"
    gui_mask = np.zeros(len(gui), dtype=bool)
    for obsid in bad_obsids.bad_obsids:
        gui_mask[gui['obsid'] == obsid] = True
    gui = gui[~gui_mask]
    t_gui = Table(gui[['id', 'kalman_tstart']])
    t_gui['no_trak'] = (gui['not_tracking_samples']
                        / gui['n_samples'])
    sum_gui = t_gui.group_by('id').groups.aggregate(np.size)
    med_gui = t_gui.group_by('id').groups.aggregate(np.median)
    bad_gui = join(sum_gui, med_gui, keys='id')[
        ['id', 'kalman_tstart_2', 'kalman_tstart_1', 'no_trak_2']]
    bad_gui.rename_column('kalman_tstart_2', 'kalman_tstart')
    bad_gui.rename_column('kalman_tstart_1', 'attempts')
    bad_gui.rename_column('no_trak_2', 'med_no_trak')

    prev_bad = []
    for line in agasc_bad.split('\n'):
        agasc_match = re.match('^(\d{4}\d+)', line)
        if agasc_match:
                prev_bad.append(int(agasc_match.group(1)))

    prev_bad = np.array(prev_bad)
    new_acq_bad = bad_acq[((bad_acq['attempts'] >= acq_n)
                           & (bad_acq['failures'] / bad_acq['attempts'] >= acq_fail))]['agasc_id']
    new_gui_bad = bad_gui[(bad_gui['attempts'] >= gui_n)
                          & (bad_gui['med_no_trak'] >= gui_med)]['id']

    all_bad = np.unique(np.append(new_acq_bad, new_gui_bad))
    new_bad = []
    for star in all_bad:
        if not any(prev_bad == star):
            new_bad.append(star)

    bad_star_h = open(file, 'w')
    bad_star_h.write(agasc_bad)
    bad_star_h.write(
        "# New stars on {} from agasc_bad/bad_stars.py\n".format(DateTime().date))

    for star in new_bad:
        acq_fail = bad_acq[bad_acq['agasc_id'] == star]
        gui_match = bad_gui[bad_gui['id'] == star]
        gui_fail = gui_match[(gui_match['med_no_trak'] >= gui_med)
                             & (gui_match['attempts'] >= gui_n)]
        if len(acq_fail) and len(gui_fail):
            # If used as an ACQ and also has a bad GUI history, add it to the list
            bad_star_h.write("%d " % star)
            bad_star_h.write(
                "| ACQ Failed %d of %d attempts | GUI Not Tracked Median %.1f %s, %d attempts |" % (
                    acq_fail[0]['failures'], acq_fail[0]['attempts'],
                    gui_fail[0]['med_no_trak'] * 100., '%', gui_fail[0]['attempts']))
            bad_star_h.write("\n")
        if len(acq_fail) and not len(gui_match):
            # If failed as an acq and never used as a guide, add it to the list
            bad_star_h.write("%d " % star)
            bad_star_h.write(
                "| ACQ Failed %d of %d attempts | No GUI |" % (
                    acq_fail[0]['failures'], acq_fail[0]['attempts']))
            bad_star_h.write("\n")
        if not len(acq_fail) and len(gui_fail):
            # If it is a bad guide star but has no ACQ history, add it to the list
            bad_star_h.write("%d " % star)
            bad_star_h.write(
                "| No ACQ | GUI Not Tracked Median %.1f %s, %d attempts |" % (
                    gui_fail[0]['med_no_trak'] * 100., '%', gui_fail[0]['attempts']))
            bad_star_h.write("\n")

    bad_star_h.close()

    # read the new file back in, instead of keeping a list in the logic above
    sausage_list = []
    new_list = open(file).read()
    for line in new_list.split('\n'):
        agasc_match = re.match('^(\d{4}\d+)', line)
        if agasc_match:
            sausage_list.append(int(agasc_match.group(1)))
    all_star_list = open('sausage_list.txt', 'w')
    for star in sorted(sausage_list):
        all_star_list.write("%10d\n" % star)
    all_star_list.close()


def starcheck_acq_list(bad_acq_table):
    bad_acq_table.rename_column('attempts', 'n_obs')
    bad_acq_table.rename_column('failures', 'n_noids')
    # reorder columns if needed
    bad_acq_table = bad_acq_table[['agasc_id', 'n_noids', 'n_obs']]
    bad_acq_table.write('test_bad_acq_stars.rdb')


def starcheck_gui_list(gui, no_trak_frac=0.05):
    # This takes the full guide list as input because it makes
    # a boolean to define a "bad" observation based on exceeding the
    # no_trak_frac instead of using the median no-trak fraction
    t_gui = Table(gui[['id']])
    t_gui['n_nbad'] = ((gui['not_tracking_samples'] / gui['n_samples'])
                       > no_trak_frac).astype(int)
    t_gui['n_obs'] = np.ones(len(gui), dtype=int)
    sum_gui = t_gui.group_by('id').groups.aggregate(np.sum)[
        ['id', 'n_nbad', 'n_obs']]
    sum_gui.rename_column('id', 'agasc_id')
    # Limit to those with at least one failure
    sum_gui = sum_gui[sum_gui['n_nbad'] > 0]
    sum_gui.write('test_bad_gui_stars.rdb')


def main():

    # Read in acquisition statistics from a pkl if present or get from the
    # database
    acq_file = 'acq.pkl'
    if os.path.exists(acq_file):
        f = open(acq_file, 'r')
        acq = pickle.load(f)
        f.close()
    else:
        acq_query = """select * from acq_stats_data"""
        acq = dbh.fetchall(acq_query)
        f = open(acq_file, 'w')
        pickle.dump(acq, f)
        f.close()

    # Exclude bad obsids "in place"
    acq_mask = np.zeros(len(acq), dtype=bool)
    for obsid in bad_obsids.bad_obsids:
        acq_mask[acq['obsid'] == obsid] = True
    acq = acq[~acq_mask]
    # Use table grouping operations to make a table of agasc ids and their
    # failures.  This is used by the sausage list and the starcheck list
    long_acqs = Table(acq[['agasc_id', 'obc_id', 'tstart']])
    all_acqs = long_acqs[['agasc_id', 'tstart']].group_by('agasc_id').groups.aggregate(np.size)
    acqs_noid = long_acqs[long_acqs['obc_id'] == 'NOID']
    bacqs = acqs_noid.group_by('agasc_id').groups.aggregate(np.size)
    bad_acqs = join(all_acqs, bacqs, keys='agasc_id')[['agasc_id', 'tstart_1', 'tstart_2']]
    bad_acqs.rename_column('tstart_1', 'attempts')
    bad_acqs.rename_column('tstart_2', 'failures')

    # Read in acquisition statistics from a pkl if present or get from the
    # database
    gui_file = 'gui.pkl'
    if os.path.exists(gui_file):
        f = open(gui_file, 'r')
        gui = pickle.load(f)
        f.close()
    else:
        gui_query = "select * from trak_stats_data where type != 'FID'"
        gui = dbh.fetchall(gui_query)
        f = open( gui_file, 'w')
        pickle.dump(gui, f)
        f.close()

    # The definite of a "bad" guide star is different in the sausage and starcheck lists
    # so pass the raw guide list to each
    sausage_list(gui, bad_acqs)
    starcheck_gui_list(gui)
    starcheck_acq_list(bad_acqs)


if __name__ == '__main__':
    main()






