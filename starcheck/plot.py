# Licensed under a 3-clause BSD style license - see LICENSE.rst
import os
import matplotlib.pyplot as plt

import agasc
from Chandra.Time import DateTime
import Quaternion
from Ska.quatutil import radec2yagzag
from chandra_aca.plot import bad_acq_stars, plot_stars, plot_compass


def make_plots_for_obsid(obsid, ra, dec, roll, starcat_time, catalog, outdir,
                         red_mag_lim=10.7, duration=0.0, agasc_file=None):
    """
    Make standard starcheck plots for obsid and save as pngs with standard names.
    Writes out to stars_{obsid}.png and star_view_{obsid}.png in supplied outdir.

    :param obsid:  Obsid used for file names
    :param ra: RA in degrees
    :param dec: Dec in degrees
    :param roll: Roll in degrees
    :param starcat_time: start time of observation
    :param catalog: list of dicts or other astropy.table compatible structure with conventional
                    starcheck catalog parameters for a set of ACQ/BOT/GUI/FID/MON items.
    :param outdir: output directory for png plot files
    :param red_mag_lim: faint limit
    :param duration: length of observation in seconds
    :param agasc_file: agasc_file for star lookups
    """

    # explicitly float convert these, as we may be receiving this from Perl passing strings
    ra = float(ra)
    dec = float(dec)
    roll = float(roll)

    # get the agasc field once and then use it for both plots that have stars
    stars = agasc.get_agasc_cone(ra, dec,
                                 radius=1.5,
                                 date=starcat_time,
                                 agasc_file=agasc_file)
    # We use the full star list for both the field plot and the main "catalog" plot
    # and we can save looking up the yang/zang positions twice if we add that content
    # to the stars in this wrapper
    yags, zags = radec2yagzag(stars['RA_PMCORR'], stars['DEC_PMCORR'],
                              Quaternion.Quat([ra, dec, roll]))
    stars['yang'] = yags * 3600
    stars['zang'] = zags * 3600

    bad_stars = bad_acq_stars(stars)

    cat_plot = plot_stars(attitude=[ra, dec, roll], catalog=catalog, stars=stars,
                          title="RA=%.6f Dec=%.6f Roll=%.6f" % (ra, dec, roll),
                          starcat_time=starcat_time, duration=duration,
                          bad_stars=bad_stars, red_mag_lim=red_mag_lim)
    cat_plot.savefig(os.path.join(outdir, 'stars_{}.png'.format(obsid)), dpi=150)
    plt.close(cat_plot)


