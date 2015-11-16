import os
import numpy as np
import matplotlib.pyplot as plt

from astropy.table import hstack, Table, Column
import agasc
from Chandra.Time import DateTime
import Quaternion
from Ska.quatutil import radec2yagzag
from chandra_aca import pixels_to_yagzag

# rc definitions
frontcolor = 'black'
backcolor = 'white'
plt.rcParams['lines.color'] = frontcolor
plt.rcParams['patch.edgecolor'] = frontcolor
plt.rcParams['text.color'] = frontcolor
plt.rcParams['axes.facecolor'] = backcolor
plt.rcParams['axes.edgecolor'] = frontcolor
plt.rcParams['axes.labelcolor'] = frontcolor
plt.rcParams['xtick.color'] = frontcolor
plt.rcParams['ytick.color'] = frontcolor
plt.rcParams['grid.color'] = frontcolor
plt.rcParams['figure.facecolor'] = backcolor
plt.rcParams['figure.edgecolor'] = backcolor
plt.rcParams['savefig.facecolor'] = backcolor
plt.rcParams['savefig.edgecolor'] = backcolor


BAD_STAR_COLOR = 'tomato'
BAD_STAR_ALPHA = .5
FAINT_STAR_COLOR = 'lightseagreen'
FAINT_STAR_ALPHA = .5


def symsize(mag):
    # map mags to figsizes, defining
    # mag 6 as 40 and mag 11 as 3
    # interp should leave it at the bounding value outside
    # the range
    return np.interp(mag, [6.0, 11.0], [40.0, 3.0])


def _plot_catalog_items(ax, catalog):
    """
    Plot catalog items (guide, acq, bot, mon, fid) in yang and zang on the supplied
    axes object in place.

    :param ax: matplotlib axes
    :param catalog: data structure containing starcheck-style columns/attributes
                    catalog records.  This can be anything that will work with
                    astropy.table.Table(catalog).  A list of dicts is the convention.
    """
    cat = Table(catalog)
    face = backcolor
    gui = cat[(cat['type'] == 'GUI') | (cat['type'] == 'BOT')]
    acq = cat[(cat['type'] == 'ACQ') | (cat['type'] == 'BOT')]
    fid = cat[cat['type'] == 'FID']
    mon = cat[cat['type'] == 'MON']
    for row in cat:
        ax.annotate("%s" % row['idx'],
                    xy=(row['yang'] - 120, row['zang'] + 60),
                    color='red',
                    fontsize=12, weight='light')
    ax.scatter(gui['yang'], gui['zang'],
               facecolors='none',
               edgecolors='green',
               s=100)
    for acq_star in acq:
        acq_box = plt.Rectangle(
            (acq_star['yang'] - acq_star['halfw'],
             acq_star['zang'] - acq_star['halfw']),
            width=acq_star['halfw'] * 2,
            height=acq_star['halfw'] * 2,
            color='blue',
            fill=False)
        ax.add_patch(acq_box)
    for mon_box in mon:
        # starcheck convention was to plot monitor boxes at 2X halfw
        box = plt.Rectangle(
            (mon_box['yang'] - (mon_box['halfw'] * 2),
             mon_box['zang'] - (mon_box['halfw'] * 2)),
            width=mon_box['halfw'] * 4,
            height=mon_box['halfw'] * 4,
            color='orange',
            fill=False)
        ax.add_patch(box)
    ax.scatter(fid['yang'], fid['zang'],
               facecolors='none',
               edgecolors='red',
               linewidth=.5,
               marker='o',
               s=175)
    ax.scatter(fid['yang'], fid['zang'],
               facecolors='none',
               edgecolors='red',
               marker='+',
               linewidth=.5,
               s=175)


def _plot_field_stars(ax, stars, quat, red_mag_lim=None, bad_stars=None):
    """
    Plot plot field stars in yang and zang on the supplied
    axes object in place.

    :param ax: matplotlib axes
    :param stars: astropy.table compatible set of records of agasc entries of stars
    :param quat: attitude quaternion as a Quat
    :param red_mag_lim: faint limit
    :param bad_stars: boolean mask of stars to be plotted in red
    """
    stars = Table(stars)

    # Add star Y angle and Z angle in arcsec to the field_stars table
    yagzags = (radec2yagzag(star['RA_PMCORR'], star['DEC_PMCORR'], quat)
               for star in stars)
    yagzags = Table(rows=[(y * 3600, z * 3600) for y, z in yagzags], names=['yang', 'zang'])
    stars = hstack([stars, yagzags])
    ok = np.ones(len(stars), dtype='bool')

    if red_mag_lim:
        nsigma = 3.0
        mag_error_low_limit = 1.5
        randerr = 0.26
        caterr = stars['MAG_ACA_ERR'] / 100.
        error = nsigma * np.sqrt(randerr*randerr + caterr*caterr)
        error[error < mag_error_low_limit] = mag_error_low_limit
        faint = ((stars['MAG_ACA'] >= red_mag_lim)
                 & ((stars['MAG_ACA'] - error) < red_mag_lim))
        too_dim_to_plot = ((stars['MAG_ACA'] >= red_mag_lim)
                            & ((stars['MAG_ACA'] - error) >= red_mag_lim))
        # All of the indices are on stars, so reindex without too_dim_to_plot
        stars = stars[~too_dim_to_plot]
        faint = faint[~too_dim_to_plot]
        ok = ok[~too_dim_to_plot]
        ok[faint] = False
        if bad_stars is not None:
            bad_stars = bad_stars[~too_dim_to_plot]
    if bad_stars is not None:
        ok[bad_stars] = False

    size = symsize(stars['MAG_ACA'])
    ax.scatter(stars[ok]['yang'], stars[ok]['zang'],
               c='black', s=size[ok])
    if red_mag_lim:
        ax.scatter(stars[faint]['yang'], stars[faint]['zang'],
                   c=FAINT_STAR_COLOR, s=size[faint], edgecolor='none',
                   alpha=FAINT_STAR_ALPHA)
    if bad_stars is not None:
        ax.scatter(stars[bad_stars]['yang'], stars[bad_stars]['zang'],
                   c=BAD_STAR_COLOR, s=size[bad_stars], edgecolor='none',
                   alpha=BAD_STAR_ALPHA)



def star_plot(catalog=None, attitude=None, stars=None, title=None,
              red_mag_lim=None, quad_bound=True, grid=True, bad_stars=None):
    """
    Plot a starcheck catalog, a star field, or both in a matplotlib figure.
    If supplying a star field, an attitude must also be supplied.

    :param catalog: Records describing starcheck catalog.  Must be astropy table compatible.
    :param attitude: A Quaternion compatible attitude for the pointing
    :param stars: astropy table compatible set of agasc records of stars
    :param title: string to be used as suptitle for the figure
    :param red_mag_lim: faint limit for field star plotting.
    :param quad_bound: boolean, plot inner quadrant boundaries
    :param grid: boolean, plot axis grid
    :param bad_stars: boolean mask on 'stars' of those that don't meet minimum requirements
                      to be selected as acq stars
    :returns: matplotlib figure
    """
    fig = plt.figure(figsize=(5.325, 5.325))
    ax = fig.add_subplot(1, 1, 1)
    plt.subplots_adjust(top=0.95)
    ax.set_aspect('equal')

    # plot the box and set the labels
    plt.xlim(2900, -2900)
    plt.ylim(-2900, 2900)
    b1hw = 2560
    box1 = plt.Rectangle((b1hw, -b1hw), -2 * b1hw, 2 * b1hw,
                         fill=False)
    ax.add_patch(box1)
    b2w = 2600
    box2 = plt.Rectangle((b2w, -b1hw), -4 + -2 * b2w, 2 * b1hw,
                         fill=False)
    ax.add_patch(box2)

    ax.scatter([-2700, -2700, -2700, -2700, -2700],
               [2400, 2100, 1800, 1500, 1200],
               c='orange', edgecolors='none',
               s=symsize(np.array([10.0, 9.0, 8.0, 7.0, 6.0])))

    [l.set_rotation(90) for l in ax.get_yticklabels()]
    ax.grid(grid)
    ax.set_ylabel("Zag (arcsec)")
    ax.set_xlabel("Yag (arcsec)")

    if quad_bound:
        pix_range = np.linspace(-510, 510, 50)
        minus_half_pix = -0.5 * np.ones_like(pix_range)
        # plot the row = -0.5 line
        yag, zag = pixels_to_yagzag(minus_half_pix, pix_range)
        ax.plot(yag, zag, color='magenta', alpha=.4)
        # plot the col = -0.5 line
        yag, zag = pixels_to_yagzag(pix_range, minus_half_pix)
        ax.plot(yag, zag, color='magenta', alpha=.4)

    # plot field if present
    if stars is not None:
        if attitude is None:
            raise ValueError("Must supply attitude to plot field stars")
        _plot_field_stars(ax, stars, Quaternion.Quat(attitude),
                          bad_stars=bad_stars, red_mag_lim=red_mag_lim)
    # plot starcheck catalog
    if catalog is not None:
        _plot_catalog_items(ax, catalog)
    if title is not None:
        fig.suptitle(title, fontsize='small')
    return fig


def make_plots_for_obsid(obsid, ra, dec, roll, starcat_time, catalog, outdir, red_mag_lim=10.7):
    """
    Make standard starcheck plots for obsid and save as pngs with standard names.
    Writes out to stars_{obsid}.png and star_view_{obsid}.png in supplied outdir.

    :param obsid:  Obsid used for file names
    :param ra: RA in degrees
    :param dec: Dec in degrees
    :param roll: Roll in degrees

    :param catalog: list of dicts or other astropy.table compatible structure with conventional
                    starcheck catalog parameters for a set of ACQ/BOT/GUI/FID/MON items.
    :param outdir: output directory for png plot files
    :param red_mag_lim: faint limit
    """

    # explicitly float convert these, as we may be receiving this from Perl passing strings
    ra = float(ra)
    dec = float(dec)
    roll = float(roll)
    # get the agasc field once and then use it for both plots that have stars
    field_stars = agasc.get_agasc_cone(ra, dec,
                                       radius=1.5,
                                       date=DateTime(starcat_time).date)

    # Mark bad stars from current limits in characteristics
    bad_stars = ((field_stars['CLASS'] != 0) | (field_stars['MAG_ACA_ERR'] > 100) |
                 (field_stars['POS_ERR'] > 3000) | (field_stars['ASPQ1'] > 0) |
                 (field_stars['ASPQ2'] > 0) | (field_stars['ASPQ3'] > 999) |
                 (field_stars['VAR'] > -9999))
    f_plot = plot_star_field(ra, dec, roll, starcat_time, stars=field_stars,
                             bad_stars=bad_stars, red_mag_lim=None)
    f_plot.savefig(os.path.join(outdir, 'star_view_{}.png'.format(obsid)), dpi=80)
    plt.close(f_plot)
    cat_plot = plot_starcheck_catalog(ra, dec, roll, catalog, starcat_time, stars=field_stars,
                                      bad_stars=bad_stars,
                                      title="RA=%.6f Dec=%.6f Roll=%.6f" % (ra, dec, roll),
                                      red_mag_lim=red_mag_lim)
    cat_plot.savefig(os.path.join(outdir, 'stars_{}.png'.format(obsid)), dpi=80)
    plt.close(cat_plot)
    compass_plot = plot_compass(roll)
    compass_plot.savefig(os.path.join(outdir, 'compass{}.png'.format(obsid)), dpi=80)
    plt.close(compass_plot)


def plot_starcheck_catalog(ra, dec, roll, catalog, starcat_time=DateTime(),
                           stars=None, bad_stars=None, red_mag_lim=None, title=None):
    """
    Make standard starcheck catalog plot with a star field and the elements of a catalog.

    :param ra: RA in degrees
    :param dec: Dec in degrees
    :param roll: Roll in degrees
    :param catalog: list of dicts or other astropy.table compatible record structure with
                    conventional starcheck catalog parameters for a set of
                    ACQ/BOT/GUI/FID/MON items.
    :param starcat_time: star catalog time.  Used as time for proper motion correction.
    :param stars: astropy table compatible set of agasc records of stars.  If not supplied,
                  these will be fetched for the supplied attitude
    :param bad_stars: mask of stars that should be plotted in red
    :param title: string to be used as suptitle for the figure
    :returns: matplotlib figure
    """
    if stars is None:
        stars = agasc.get_agasc_cone(ra, dec,
                                     radius=1.5,
                                     date=DateTime(starcat_time).date)
    fig = star_plot(catalog, attitude=[ra, dec, roll], stars=stars, title=title,
                    bad_stars=bad_stars, red_mag_lim=red_mag_lim)
    return fig


def plot_star_field(ra, dec, roll, starcat_time=DateTime(), stars=None, bad_stars=None,
                    red_mag_lim=None, title=None):
    """
    Make standard starcheck star field plot.

    :param ra: RA in degrees
    :param dec: Dec in degrees
    :param roll: Roll in degrees
    :param starcat_time: star catalog time.  Used as time for proper motion correction.
    :param stars: astropy table compatible set of agasc records of stars.  If not supplied,
                  these will be fetched for the supplied attitude
    :param bad_stars: mask of stars that should be plotted in red
    :param title: string to be used as suptitle for the figure
    :returns: matplotlib figure
    """
    if stars is None:
        stars = agasc.get_agasc_cone(ra, dec,
                                     radius=1.5,
                                     date=DateTime(starcat_time).date)
    fig = star_plot(catalog=None, attitude=[ra, dec, roll], stars=stars, title=title,
                    quad_bound=False, red_mag_lim=red_mag_lim, bad_stars=bad_stars)
    return fig


def plot_compass(roll):
    """
    Make a compass plot.

    :param roll: Attitude roll for compass plot.
    :returns: matplotlib figure
    """
    fig = plt.figure(figsize=(3, 3))
    ax = plt.subplot(polar=True)
    ax.annotate("", xy=(0, 0), xytext=(0, 1),
                arrowprops=dict(arrowstyle="<-", color="k"))
    ax.annotate("", xy=(0, 0), xytext=(np.radians(90), 1),
                arrowprops=dict(arrowstyle="<-", color="k"))
    ax.annotate("N", xy=(0, 0), xytext=(0, 1.2))
    ax.annotate("E", xy=(0, 0), xytext=(np.radians(90), 1.2))
    ax.set_theta_offset(np.radians(90 + roll))
    ax.grid(False)
    ax.set_yticklabels([])
    plt.ylim(0, 1.4)
    plt.tight_layout()
    return fig
