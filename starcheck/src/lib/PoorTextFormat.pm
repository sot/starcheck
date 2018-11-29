package PoorTextFormat;

##***************************************************************************
#  
# History:
#   9-May-00  Fixed bug with linked target in 'text'
#     Apr-00  Created (TLA)
#
##***************************************************************************

#

use English;

$cmd{latex} = {
    list_preamble => '\begin{itemize}',
    list_start    => '\item',
    list_end      => '',
    list_postamble=> '\end{itemize}',
};

$cmd{text} = {
    line_start    => '',
    line_end      => '',
    list_start    => '',
    list_end      => '',
    item_start    => ' * ',
    item_end      => '',
    fixed_start   => '',
    fixed_end     => '',
    red_start     => '',
    red_end       => '',
    green_start     => '',
    green_end       => '',
    yellow_start     => '',
    yellow_end       => '',
    link_target_middle => '',
    link_target_end    => '',
    page_break    => "====================================================================================\n",
};

$preamble{text} = '';
$postamble{text} = '';

$cmd{html} = {
    line_start    => '',
    line_end      => '',
    list_start    => '<ul>',
    list_end      => '</ul>',
    item_start    => '<li>',
    item_end      => '</li>',
    fixed_start   => '<pre>',
    fixed_end     => '</pre>',
    red_start     => '<font color="#FF0000">',
    red_end       => '</font>',
    blue_start     => '<font color="#0000FF">',
    blue_end       => '</font>',
    green_start     => '<font color="#00FF00">',
    green_end       => '</font>',
    yellow_start     => '<font color="#009900">',
    yellow_end       => '</font>',
    image_start   => '<img SRC="',
    image_end     => '"><br>',
    page_break    => '<br><hr WIDTH="100%">',
    target_start  => '<a NAME="',
    target_end    => '"></a>',
    link_target_start  => '<a href="',
    link_target_middle => '">',
    link_target_end    => '</a>',
    html_start => qq{ },
    html_end => qq{ },
};

$preamble{html} = <<'END_HTML_PREAMBLE'
<!doctype html public "-//w3c//dtd html 4.0 transitional//en">
<html>
<head>
   <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1">
   <meta name="GENERATOR" content="Mozilla/4.51 [en] (X11; U; SunOS 5.6 sun4u) [Netscape]">
</head>
<body bgcolor="#FFFFFF">
END_HTML_PREAMBLE
    ;

$postamble{html} = <<'END_HTML_POSTAMBLE'
</body>
</html>
END_HTML_POSTAMBLE
    ;

1;

##************************************************************************
sub new {
##************************************************************************
    my $classname = shift;
    my $self = {};
    bless ($self);

    return $self;
}

##************************************************************************
sub ptf2any {
##************************************************************************
    $self = shift;
    $fmt = shift;		# Output format
    @ptf  = split "\n", shift;	# Input ptf text to translate

    return unless (exists $cmd{$fmt});

    $line_start = $cmd{$fmt}->{line_start};
    $line_end = $cmd{$fmt}->{line_end};

    my $out = $preamble{$fmt};
    
    foreach (@ptf) {
	chomp;
	if (/\\(\S+{[^}]*})/ || /\\(\S+) ?/) {	# There is a PTF command
	    $ptf_cmd = $1;
	    my $postmatch = $POSTMATCH;
#	    print STDERR "PTF_CMD = $ptf_cmd\n";
#	    print STDERR "postmatch0 = :$POSTMATCH:\n";
	    $out .= $PREMATCH;
	    $out .= $cmd{$fmt}->{$ptf_cmd} if (exists $cmd{$fmt}->{$ptf_cmd});

	    # Command specific special processing
	    if ($ptf_cmd eq 'list_start') {
		$line_start = $cmd{$fmt}->{item_start};
	    }
	    if ($ptf_cmd eq 'list_start') {
		$line_end = $cmd{$fmt}->{item_end};
	    }
	    if ($ptf_cmd eq 'list_end') {
		$line_start = $cmd{$fmt}->{line_start};
	    }
	    if ($ptf_cmd eq 'list_end') {
		$line_end = $cmd{$fmt}->{line_end};
	    }
	    if ($ptf_cmd eq 'image') {
		if ($cmd{$fmt}->{image_start}) {
		    $out .=  $cmd{$fmt}->{image_start} . $POSTMATCH . $cmd{$fmt}->{image_end} . "\n";
		}
		next;		# Rest of line is ignored
	    }
	    if ($ptf_cmd eq 'html') {
		if ($cmd{$fmt}->{html_start}) {
		    $out .= $cmd{$fmt}->{html_start} . $POSTMATCH . $cmd{$fmt}->{html_end} . "\n";
		}
		next;
	    }
	    
	    if ($ptf_cmd =~ /^target\{([^}]*)\}/) {
		if ($cmd{$fmt}->{target_start}) {
		    $out .=  $cmd{$fmt}->{target_start} . $1 . $cmd{$fmt}->{target_end};
		}
	    }

	    if ($ptf_cmd =~ /^link_target\{[^}]*\}/) {
		if (exists $cmd{$fmt}->{link_target_end}) {
		    my ($target, $text) = ($ptf_cmd =~ /\{([^,]+),([^,]+)\}/);
		    $out .=  $cmd{$fmt}->{link_target_start} . $target
			if ($cmd{$fmt}->{link_target_start});
		    $out .=  $cmd{$fmt}->{link_target_middle}
			     . $text
			     . $cmd{$fmt}->{link_target_end};
		}
	    }

	    $_ = $postmatch;
	    redo; # if (/\S/ || $PREMATCH);	# Redo only if there is non-trivial stuff left over
	} else {
	    $out .= "$line_start$_$line_end\n";
	}
    }

    $out .= $postamble{$fmt};
}
