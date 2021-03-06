package Koha::Solr::Z3950Service;

# Copyright 2012 PTFS/LibLime
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA

use 5.008;
use strict;
use warnings;

use Data::Dumper; # For debugging output only
use XML::Simple;
use Net::Z3950::SimpleServer;
use Net::Z3950::OID;
use ZOOM;
use LWP::UserAgent;		# For access to HTTP-based authenticator
use URI::Escape;
use XML::LibXML;
use MARC::Record;
use MARC::File::XML;
use Time::HiRes qw(gettimeofday tv_interval);

our @ISA = qw();
our $VERSION = '1.04';
our $TIME = 0;


=head1 NAME

Koha::Solr::Z3950Service - Gateway between Z39.50 and Solr

=head1 SYNOPSIS

 use Koha::Solr::Z3950Service;
 $s2z = new Koha::Solr::Z3950Service("somefile.xml");
 $s2z->launch_server("someServer", @ARGV);

=head1 DESCRIPTION

The C<Koha::Solr::Z3950Service> module provides all the application
logic of a generic "Swiss Army Gateway" between Z39.50 and SRU.  It is
used by the C<simple2zoom> program, and there is probably no good
reason to make any other program to use it.  For that reason, this
library-level documentation is more than usually terse.

The library has only two public entry points: the C<new()> constructor
and the C<launch_server()> method.  The synopsis above shows how they
are used: a Z3950Service object is created using C<new()>, then the
C<launch_server()> method is invoked on it to -- get ready for a big
surprise here -- launch the server.  (In fact, this synopsis is
essentially the whole of the code of the C<simple2zoom> program.  All
the work happens inside the library.)

=head1 METHODS

=head2 new($configFile)

 $s2z = new Koha::Solr::Z3950Service("somefile.xml");

Creates and returns a new Z3950Service object, configured according to
the XML file C<$configFile> that is the only argument.  The format of
this file is described in C<Koha::Solr::Z3950Service::Config>.

=cut

sub new {
    my $class = shift();
    my($cfgfile) = @_;

    my $this = bless {
	cfgfile => $cfgfile || 'client.xml',
	cfg => undef,
    }, $class;

    $this->_reload_config_file();
    $this->_set_defaults();

    if (1) {
	foreach my $base (sort keys %{ $this->{cfg}->{database} }) {
	    warn "Found database: $base\n";
	}
    }

    $this->{server} = Net::Z3950::SimpleServer->new(
	GHANDLE => $this,
	INIT =>    \&_init_handler,
	SEARCH =>  \&_search_handler,
	PRESENT => \&_present_handler,
	FETCH =>   \&_fetch_handler,
	SCAN =>    \&_scan_handler,
	DELETE =>  \&_delete_handler,
	SORT   =>  \&_sort_handler,
    );

    return $this;
}


=head2 launch_server($label, @ARGV)

 $s2z->launch_server("someServer", @ARGV);

Launches the Z3950Service server: this method never returns.  The
C<$label> string is used in logging, and the C<@ARGV> vector of
command-line arguments is interpreted by the YAZ backend server as
described at
http://www.indexdata.dk/yaz/doc/server.invocation.tkl

=cut

sub launch_server {
    my $this = shift();
    my($label, @argv) = @_;

    return $this->{server}->launch_server($label, @argv);
}


sub _init_handler { _eval_wrapper(\&_real_init_handler, @_) }
sub _search_handler { _eval_wrapper(\&_real_search_handler, @_) }
sub _present_handler { _eval_wrapper(\&_real_present_handler, @_) }
sub _fetch_handler { _eval_wrapper(\&_real_fetch_handler, @_) }
sub _scan_handler { _eval_wrapper(\&_real_scan_handler, @_) }
# No _eval_wrapper for DELETE since it doesn't use ERR_CODE/ERR_STR
sub _sort_handler { _eval_wrapper(\&_real_sort_handler, @_) }


# This can be used by the _real_*_handler() callbacks to signal
# exceptions that will be caught by _eval_wrapper() and translated
# into BIB-1 diagnostics for the client
#
sub _throw {
    my($code, $addinfo, $diagset) = @_;
    $diagset ||= "Bib-1";
    die new ZOOM::Exception($code, undef, $addinfo, $diagset);
}


sub _eval_wrapper {
    my $coderef = shift();
    my $args = shift();
    my $warn = $ENV{S2Z_EXCEPTION_DEBUG} || 0;

    eval {
	&$coderef($args, @_);
    }; if (ref $@ && $@->isa('ZOOM::Exception')) {
	warn "ZOOM error $@" if $warn > 1;
	if ($@->diagset() eq 'Bib-1') {
	    warn "Bib-1 ZOOM error" if $warn > 0;
	    $args->{ERR_CODE} = $@->code();
	    $args->{ERR_STR} = $@->addinfo();
	} elsif ($@->diagset() eq 'info:srw/diagnostic/1') {
	    warn "SRU ZOOM error" if $warn > 0;
	    $args->{ERR_CODE} =
		Net::Z3950::SimpleServer::yaz_diag_srw_to_bib1($@->code());
	    $args->{ERR_STR} = $@->addinfo();
	} elsif ($@->diagset() eq 'ZOOM' &&
		 $@->code() eq ZOOM::Error::CONNECT) {
	    # Special case for when the host is down
	    warn "Special case: host unavailable" if $warn > 0;
	    $args->{ERR_CODE} = 109;
	    $args->{ERR_STR} = $@->addinfo();
	} else {
	    warn "Non-Bib-1, non-SRU ZOOM error" if $warn > 0;
	    $args->{ERR_CODE} = 100;
	    $args->{ERR_STR} = $@->message() || $@->addinfo();
	}
    } elsif ($@) {
	# Non-ZOOM exceptions may be generated by the Perl
	# interpreter, for example if we try to call a method that
	# does not exist in the relevant class.  These should be
	# considered fatal and not reported to the client.
	die $@;
    }
}


sub _real_init_handler {
    my($args) = @_;
    my $gh = $args->{GHANDLE};

    die "GHANDLE not defined: is your SimpleServer too old?  (Need 1.06)"
	if !defined $gh;
    $gh->_reload_config_file();

    my $user = $args->{USER};
    my $pass = $args->{PASS};
    # Initialise session data.  This data structure should probably be
    # a private data structure, Koha::Solr::Z3950Service::Session or
    # similar.
    $args->{HANDLE} = {
	connections => {}, # maps dbname to ZOOM::Connection
	resultsets => {},  # result sets, indexed by setname
	username => $user || '',
	password => $pass || '',
    };

    $args->{IMP_ID} = '81';
    $args->{IMP_VER} = $Koha::Solr::Z3950Service::VERSION;
    $args->{IMP_NAME} = 'Koha Koha::Solr::Z3950Service Universal Gateway';

    my $auth = $gh->{cfg}->{authentication};
    if (defined $auth) {
	# Init/AC: Authentication System error
	_throw(1014, "credentials not supplied")
	    if !defined $user || !defined $pass;
	my $quser = uri_escape($user); $auth =~ s/{user}/$quser/;
	my $qpass = uri_escape($pass); $auth =~ s/{pass}/$qpass/;

	#warn "Authenticating at $auth";
	my $ua = new LWP::UserAgent();
	$ua->agent("Koha::Solr::Z3950Service $VERSION");
	my $req = new HTTP::Request(GET => $auth);
	my $res = $ua->request($req);
	_throw(1014, "credentials are bad")
	    if !$res->is_success();
    }
}


sub _real_search_handler {
    my($args) = @_;
    my $session = $args->{HANDLE};

    my($zdbname, $dbconfig) = _extract_database($args);

    # For now, we only accept Z39.50 Type-1 queries from the client.
    # SimpleServer is also quite happy to pass through raw CQL if
    # that's what the client (Z39.50 or SRU) sends, but that's less
    # common, and is not required by NLA.  We compound this felony by
    # supporting only one attribute-set -- BIB-1, of course.

    my($qtext, $query);
    if ($dbconfig->{search} && $dbconfig->{search}->{querytype} eq 'cql') {
	my $type1 = $args->{RPN}->{query};
	$qtext = $type1->_toCQL($args, $args->{RPN}->{attributeSet});
	warn "search: translated '" . $args->{QUERY} . "' to '$qtext'\n";
	$query = new ZOOM::Query::CQL($qtext);
    } elsif ($dbconfig->{search} && $dbconfig->{search}->{querytype} eq 'solr') {
	my $type1 = $args->{RPN}->{query};
	$qtext = $type1->_toSolr($args, $args->{RPN}->{attributeSet});
	warn "search: translated '" . $args->{QUERY} . "' to '$qtext'\n";
	$query = new ZOOM::Query::CQL($qtext);
    } else {
	$qtext = $args->{QUERY};
	$query = new ZOOM::Query::PQF($qtext);
    }

    _throw(22)
	if $dbconfig->{nonamedresultsets} && $args->{SETNAME} ne 'default';

    my $search = _do_search($session, $zdbname, $dbconfig,
			    $args->{SETNAME}, $qtext, $query);
    $args->{HITS} = $search->{hits};
}


sub _real_present_handler {
    my($args) = @_;
    my $session = $args->{HANDLE};

    my $set = $session->{resultsets}->{$args->{SETNAME}};
    _throw(30, $args->{SETNAME}) if !$set; # Result set does not exist

    my $start = $args->{START};
    my $number = $args->{NUMBER};

    # Present out of range.  This is actually not necessary, as the
    # GFS makes the check and the present-handler is not called if it
    # fails.
    _throw(13) if ($start > $set->{hits} ||
		   $start + $number - 1 > $set->{hits});

    my $rs = $set->{resultset};
    #warn "about to request $number records from $start";
    $rs->records($start-1, $number, 0);
    #warn "request $number records from $start";
}


sub _real_fetch_handler {
    my($args) = @_;
    my $session = $args->{HANDLE};

    my $set = $session->{resultsets}->{$args->{SETNAME}};
    _throw(30, $args->{SETNAME}) if !$set; # Result set does not exist

    my $dbconfig = $set->{dbConfig};
    my $charset = 'charset=utf8';
    if ($dbconfig->{charset}) {
        $charset .= ",$dbconfig->{charset}";
    }

    my $rs = $set->{resultset};
    my $schema = $args->{REQ_FORM};
    my $sconfig = $dbconfig->{schema}->{$schema};
    if (defined $sconfig) {
	$rs->option(schema => $sconfig->{sru});
	warn "Requesting schema '$schema' = " . $rs->option("schema") . "\n";
    }

    my $t0 = [ gettimeofday() ];
    my $rec = $rs->record($args->{OFFSET} - 1);
    print "elapsed: record = ", tv_interval($t0), "\n" if $TIME;
    my $xml = $rec->get('xml', $charset);

    # Surrogate diagnostics should be detected by ZOOM-C and testable
    # using $rec->error().  As of YAZ 3.0.10 this is not done, and we
    # need to check the returned XML by hand to see whether it's data
    # or diagnostic.  But from 3.0.12 onwards, $rec->error() works.
    my($vs, $ss) = ("x" x 100, "x" x 100); # allocate space for these strings
    my $version = Net::Z3950::ZOOM::yaz_version($vs, $ss);
    if ($version > 0x03000a) {
	my($errcode, $errmsg, $addinfo, $diagset) = $rec->error();
	_throw($errcode, $addinfo, $diagset) if $errcode != 0;
    } else {
	# We use a heuristic to determine whether we need to do the
	# full parse.
	if ($xml =~ /<.*diagnostic /) {
	    my $parser = new XML::LibXML();
	    my $node = $parser->parse_string($xml);
	    my $ns = "http://www.loc.gov/zing/srw/diagnostic/";
	    my @nodes = $node->findnodes(_nsxpath($ns, "diagnostic"));
	    if (@nodes) {
		my $sub = $nodes[0];
		my $uri = $sub->find(_nsxpath($ns, "uri"));
		my $details = $sub->find(_nsxpath($ns, "details"));
		if ($uri =~ s@info:srw/diagnostic/1/@@) {
		    my $err = Net::Z3950::SimpleServer::yaz_diag_srw_to_bib1($uri);
		    _throw($err, $details);
		} else {
		    my $msg = "unrecognised surrogate diagnostic $uri";
		    $msg .= " ($details)" if defined $details;
		    _throw(100, $msg);
		}
	    }
	}
    }

    if (defined $sconfig) {
	my $encoding = $sconfig->{encoding} || "UTF-8";
	my $format = $sconfig->{format} || "MARC21";
	my $t0 = [ gettimeofday() ];
	my $rec = MARC::Record->new_from_xml($xml, $encoding, $format);
	print "elapsed: parse = ", tv_interval($t0), "\n" if $TIME;
	$args->{RECORD} = $rec->as_usmarc();
	$t0 = [ gettimeofday() ];
	print "elapsed: usmarc = ", tv_interval($t0), "\n" if $TIME;
    } else {
	$args->{RECORD} = _format($xml, $args->{REQ_FORM}, $dbconfig);
    }
}


sub _nsxpath {
    my($ns, $elem) = @_;

    return "*[local-name() = '$elem' and namespace-uri() = '$ns']";
}


sub _format {
    my($xml, $recsyn, $dbconfig) = @_;

    my $node = XML::LibXML->new->parse_string($xml);
    $xml = $node->findvalue(q{/doc/str[@name='marcxml']});

    my %formats = (
	Net::Z3950::OID::xml =>    [ "xml",   0, undef ],
	Net::Z3950::OID::usmarc => [ "usmarc",  1, \&_format_marc ],
	Net::Z3950::OID::grs1 =>   [ "grs1",  1, \&_format_grs1 ],
	Net::Z3950::OID::sutrs =>  [ "sutrs", 0, \&_format_sutrs ],
    );

    my $format = $formats{$recsyn};
    if (!defined $format) {
      UNSUPPORTED_FORMAT:
	my @supported;
	foreach my $key (keys %formats) {
	    my $format = $formats{$key};
	    my($name, $needConf, $codeRef) = @$format;
	    push @supported, $name
		if !$needConf || defined $dbconfig->{"$name-record"};
	}
	_throw(238, join(",", sort @supported));
    }

    my($name, $needConf, $codeRef) = @$format;
    my $config = $dbconfig->{"$name-record"};
    goto UNSUPPORTED_FORMAT if $needConf && !defined $config;

    if (my $explicit = $dbconfig->{option}{explicit_availability}) {
        my $fudge = $explicit->{content};
        my $rec = MARC::Record->new_from_xml($xml, 'UTF-8');
        for ( $rec->field('952') ) {
            next if defined $_->subfield('q');
            $_->add_subfields('q', $fudge);
        }
        $xml = $rec->as_xml;
    }

    return $xml if !defined $codeRef;
    return &$codeRef($xml, $config);
}


sub _real_scan_handler {
    my($args) = @_;
    my $session = $args->{HANDLE};

    my($zdbname, $dbconfig) = _extract_database($args);
    my $connection = _get_connection($session, $zdbname, $dbconfig);

    $connection->option(number => $args->{NUMBER});
    $connection->option(position => $args->{POS});
    $connection->option(stepSize => $args->{STEP});

    my $query;
    if ($dbconfig->{search} && $dbconfig->{search}->{querytype} eq 'cql') {
	my $type1 = $args->{RPN};
	# It's a bit naughty, but very convenient, to assume BIB-1 here
	my $cql = $type1->_toCQL($args, "1.2.840.10003.3.1");
	warn "scan: translated '" . $type1->toPQF() . "' to '$cql'\n";
	$query = new ZOOM::Query::CQL($cql);
    } else {
	$query = new ZOOM::Query::PQF($args->{RPN}->toPQF());
    }

    #warn "about to scan";
    my $t0 = [ gettimeofday() ];
    my $ss = $connection->scan($query);
    print "elapsed: scan = ", tv_interval($t0), "\n" if $TIME;
    my $n = $ss->size();
    #warn "scanset=$ss, n=$n\n";
    $args->{STATUS} = ($n == $args->{NUMBER}) ?
	Net::Z3950::SimpleServer::ScanSuccess :
	Net::Z3950::SimpleServer::ScanPartial;

    $args->{NUMBER}  = $n;
    my @entries = ();
    for (my $i = 0; $i < $n; $i++) {
	my($term, $occ) = $ss->term($i);
	push @entries, { TERM => $term, OCCURRENCE => $occ };
    }

    $args->{ENTRIES} = \@entries;
}


sub _delete_handler {
    my($args) = @_;

    # Now what?  There is no Delete Result Set operation in ZOOM-C,
    # and therefore in ZOOM-Perl, so we can't just call $rs->delete().
    # Worse, there is no Delete Result Set operation in the SRU
    # protocol, so there is nothing really to be done here.  We could
    # have ZOOM-C send a search for cql.resultSetId=xxx with TTL=0,
    # but that is probably not recognised by most (any?) servers.  So
    # probably the best thing we can do is ... nothing!

    $args->{STATUS} = 0;
}


# The Right Thing here is just to use $rs->sort().  However, ZOOM-C
# does not support Sort for SRU connections, but sneakily sends a
# Z39.50 sort APDU.  (This is not as unreasonable as it sounds, given
# that SRU has no Sort operation.)
#
# Instead, for SRU connections, we need to send a new search
# consisting of the previous search's result-set ID and the relevant
# sort-specification.  The same approach will work with Z39.50,
# bypassing the use of the Sort service, although that seems a bit
# perverted in the case of a protocol that deliberately provides one.
#
# One approach would be look for an "http:" at the start of the
# zdbname to see whether the connection uses Z39.50 or SRU, and tailor
# the behaviour accordingly.  But it is really the job of the ZOOM
# abstraction to do this.  Until ZOOM-C is fixed to do SRU sorting by
# re-searching, then, the least of the available evils is probably
# just to always use the re-searching approach.
#
sub _real_sort_handler {
    my($args) = @_;
    my $session = $args->{HANDLE};

    if (0) {
	my %a2 = %$args;
	delete $a2{GHANDLE};
	delete $a2{HANDLE};
	print Dumper(\%a2);
    }

    # Determine the query language to use for the back-end.  Since no
    # database name is included in the Sort request, we need to look
    # up database name by result set.  If we have multiple input
    # result sets, then it's possible that they will use different
    # protocols, but we can't help that.  Just trust the first.
    my $in = $args->{INPUT};
    my $rs = $session->{resultsets}->{$in->[0]};
    my($zdbname, $dbconfig);
    {
	local $args->{DATABASES} = [ $rs->{dbName} ];
	($zdbname, $dbconfig) = _extract_database($args);
    }

    my($qtext, $sortspec, $query);
    if (!$dbconfig->{search} || $dbconfig->{search}->{querytype} ne 'cql') {
	# Type-1 query; so we have to use a YAZ sortspec
	$qtext = "";
	$qtext .= join("", map { '@or ' } 1..@$in) if @$in > 1;
	$qtext .= join(" ", map { qq[\@set "$_"] } @$in);
	$sortspec = _yaz_sortspec($args->{SEQUENCE});
	$query = new ZOOM::Query::PQF($qtext);
    } else {
	# CQL query, using v1.2 "sortby" if available.  Use RSID if
	# available; otherwise fall back to resubmitting the query.
	$qtext = join(" or ", map {
	    my $rs = $session->{resultsets}->{$_};
	    my $rsid = $rs->{rsid};
	    defined $rsid ? qq[cql.resultSetId="$rsid"] :
		("(" . $rs->{qtext} . ")");
	} @$in);

	my $conn = _get_connection($session, $zdbname, $dbconfig);
	my $sv = $conn->option("sru_version");
	#warn "sv='$sv'";
	if ($sv >= 1.2) {
	    # Use CQL-1.2 sort-specification here: $query .= $cqlsort
	    $qtext .= " sortby " . _cql_sortspec($dbconfig, $args->{SEQUENCE});
	    $query = new ZOOM::Query::CQL($qtext);
	} else {
	    $query = new ZOOM::Query::CQL($qtext);
	    $sortspec = _yaz_sortspec($args->{SEQUENCE});
	}
    }

    warn "sort: $qtext // " . ($sortspec || "[UNDEFINED]") . "\n";
    $query->sortby($sortspec) if defined $sortspec;
    _do_search($session, $zdbname, $dbconfig, $args->{OUTPUT}, $qtext, $query);
}


sub _yaz_sortspec {
    my($sequence) = @_;

    my $sortspec = "";
    foreach my $key (@$sequence) {
	$sortspec .= " " if $sortspec ne "";

	my $field = $key->{SORTFIELD};
	my $set = $key->{ATTRSET};
	my $estype = $key->{ELEMENTSPEC_TYPE};

	if (defined $field) {
	    $sortspec .= $field;
	} elsif (defined $estype) {
	    # This is total guesswork.  I've never seen one of these.
	    $sortspec .= ("$estype=" . $key->{ELEMENTSPEC_VALUE});
	} elsif (defined $set) {
	    # There may be any number of attributes, but all we're
	    # interested in is the access-point (since we can't
	    # express the others in YAZ sorting syntax).  Also, the
	    # YAZ syntax assumes that access points are BIB-1.
	    _throw(121, $set) if $set ne '1.2.840.10003.3.1';
	    my $ap;
	    foreach my $attr (@{ $key->{SORT_ATTR} }) {
		$ap = $attr->{ATTR_VALUE} if $attr->{ATTR_TYPE} == 1;
	    }
	    _throw(237, "no use attribute specified in sort key")
		if !defined $ap;
	    $sortspec .= "1=$ap";
	} else {
	    _throw(237, "sort specification contains no key");
	}

	# There is no way to express MISSING in YAZ sorting syntax
	$sortspec .= " " . ($key->{RELATION} ? ">" : "<");
	$sortspec .= $key->{CASE} ? "i" : "s";
    }

    return $sortspec;
}


sub _cql_sortspec {
    my($dbconfig, $sequence) = @_;

    my $sortspec = "";
    foreach my $key (@$sequence) {
	$sortspec .= " " if $sortspec ne "";

	my $field = $key->{SORTFIELD};
	my $set = $key->{ATTRSET};
	my $estype = $key->{ELEMENTSPEC_TYPE};

	if (defined $field) {
	    $sortspec .= $field;
	} elsif (defined $estype) {
	    # Guesswork
	    $sortspec .= "$estype/" . $key->{ELEMENTSPEC_VALUE};
	} elsif (defined $set) {
	    # Ignore all attributes but access-point (which is BIB-1)
	    _throw(121, $set) if $set ne '1.2.840.10003.3.1';
	    my $ap;
	    foreach my $attr (@{ $key->{SORT_ATTR} }) {
		$ap = $attr->{ATTR_VALUE} if $attr->{ATTR_TYPE} == 1;
	    }
	    _throw(237, "no use attribute specified in sort key")
		if !defined $ap;
	    $sortspec .= _ap2index($dbconfig, $ap);
	} else {
	    _throw(237, "sort specification contains no key");
	}

	$sortspec .= "/sort." .
	    ($key->{RELATION} ? "descending" : "ascending");
	$sortspec .= "/sort." .
	    ($key->{CASE} ? "ignoreCase" : "respectCase");
	### SimpleServer does not propagate the "missing" value, if any
	$sortspec .= "/sort.missing" .
	    ($key->{MISSING} == 1 ? "Fail" :
	     $key->{MISSING} == 2 ? "Omit" :
	     "Value=UNSPECIFIED");
    }

    return $sortspec;
}


sub _ap2index {
    my($dbconfig, $value) = @_;

    my $searchConfig = $dbconfig->{search};
    #warn "searchConfig=$searchConfig, map=" . $searchConfig->{map};
    if (!defined $searchConfig || !defined $searchConfig->{map}) {
	# This allows us to use string-valued attributes when no
	# indexes are defined.
	return $value;
    }

    my $fieldinfo = $searchConfig->{map}->{$value};
    _throw(114, $value) if !defined $fieldinfo;
    if ($fieldinfo->{index}) {
	return $fieldinfo->{index};
    } else {
	return ''; # any
    }
}


sub _reload_config_file {
    my $this = shift();

    my $cfgfile = $this->{cfgfile};
    $this->{cfg} = XML::Simple::XMLin($cfgfile,
	forceArray => ['database', 'map', 'option', 'schema'],
	keyAttr => ['use', 'name', 'oid']);
}


sub _set_defaults {
    my $this = shift();
    my $cfg = $this->{cfg};

    foreach my $dbname (keys %{ $cfg->{database} }) {
	my $db = $cfg->{database}->{$dbname};
	$db->{option} = {} if !defined defined $db->{option};
	my $opt = $db->{option};
	$opt->{presentChunk} = { content => 10 }
	    if !defined $opt->{presentChunk};
    }
}


sub _extract_database {
    my($args) = @_;
    my $gh = $args->{GHANDLE};

    # Too many databases
    _throw(111) if @{ $args->{DATABASES}} > 1;
    my $zdbname = $args->{DATABASES}->[0];

    my $dbconfig;
    if ($zdbname =~ /^cfg:/) {
        $dbconfig = $gh->_extract_config($zdbname);
    } else {
        $dbconfig = $gh->{cfg}->{database}->{$zdbname};
    }

    # Unknown database
    _throw(235, $zdbname) if !$dbconfig;

    return ($zdbname, $dbconfig);
}


sub _extract_config {
    my $this = shift();
    my($db) = @_;
    my $saved = $db;
    my ($content) = ($db =~ /cfg:(.*)/);

    my $settings = {
	timeout    => 120,
	sru        => 'get',
    };

    ### I don't think this provides a way to override charset or search
    foreach my $m (split(/&/, $content)) {
        my ($key, $value) = ($m =~ /([^=]+)=(.*)/);
        $settings->{$key} = $value;
    }

    my $config = { option => {} };
    if ( defined($settings->{address}) ) {
        $config->{zurl} = $settings->{address};
        delete $settings->{address};
    } else {
	_throw(1, "virtual database contains no address: '$saved'");
    }

    $config->{search} = $this->{cfg}->{search};

    foreach my $key (keys %$settings) {
        $config->{option}->{$key}->{content} = $settings->{$key};
    }

    return $config;
}


sub _do_search {
    my($session, $zdbname, $dbconfig, $setname, $qtext, $query) = @_;

    # This should probably be an object of some application-specific
    # class such as Koha::Solr::Z3950Service::ResultSet
    my $search = {
	dbName => $zdbname,
	dbConfig => $dbconfig,
	setname => $setname,
	qtext => $qtext,
    };

    my $conn = _get_connection($session, $zdbname, $dbconfig);
    $conn->option(presentChunk => 0);
    my $t0 = [ gettimeofday() ];
    my $rs = $conn->search($query);
    print "elapsed: search = ", tv_interval($t0), "\n" if $TIME;
    $search->{resultset} = $rs;
    $search->{hits} = $rs->size();
    $search->{rsid} = $rs->option("resultSetId");

    $session->{resultsets}->{$setname} = $search;
    return $search;
}


sub _get_connection {
    my($session, $zdbname, $dbconfig) = @_;

    my $connection = $session->{connections}->{$zdbname};
    if (!$connection) {
	my $options = new ZOOM::Options();
	$options->option(presentChunk => 10);
	$options->option(preferredRecordSyntax => "xml");

	my $user = $session->{username};
	if (defined $user && $user ne "") {
	    #warn "Using username '$user'";
	    $options->option(user => $user);
	}

	my $password = $session->{password};
	if (defined $password && $password ne "") {
	    #warn "Using password '$password'";
	    $options->option(password => $password);
	}

	foreach my $key (keys %{ $dbconfig->{option} }) {
	    my $value = $dbconfig->{option}->{$key}->{content};
	    $options->option($key => $value);
	}

	$connection = create ZOOM::Connection($options);
	$connection->connect($dbconfig->{zurl});
	$session->{connections}->{$zdbname} = $connection;
    }

    return $connection;
}


sub _format_marc {
    my($xml, $config) = @_;

    my @fields;			# List of fields, in the order
				# specified in the configuration.
    my %current;		# Maps tags to references into @fields

    my $parser = new XML::LibXML();
    my $node = $parser->parse_string($xml)->documentElement();
    foreach my $field (@{ $config->{field} }) {
	my $xpath = $field->{xpath};
	my $data = _trim_nl($node->findvalue($xpath));
	next if !defined $data || $data eq "";

	my($tag, $i1, $i2, $subtag) = ($field->{content}, "", "");

        if ($tag eq 'full') {
            my $rec = MARC::Record->new_from_xml($xml, 'UTF-8');
            return $rec->as_usmarc();
        }
	if ($tag =~ s/\$(.*)//) {
	    $subtag = $1;
	}
	if ($tag =~ s/\/(.*)//) {
	    $i1 = $1;
	    if ($i1 =~ s/\/(.*)//) {
		$i2 = $1;
	    }
	}

	if ($tag =~ /^00/) {
	    # Control fields (no subfields or indicators involved)
	    push @fields, MARC::Field->new($tag, $data);
	    next;
	}

	if (!defined $current{$tag} ||
	    defined $current{$tag}->subfield($subtag)) {
	    # Either it's the first time we've has data for this
	    # field, or we've already created this subfield within the
	    # specified field, so we need to create a new field with
	    # the same tag to hold the new subfield.
	    #print "*** creating new field '$tag' with '$subtag'='$data'\n";
	    my $marcfield = MARC::Field->new($tag, $i1, $i2, $subtag => $data);
	    push @fields, $marcfield;
	    $current{$tag} = $marcfield;
	} else {
	    # The already have this field, but the subfield is new within it.
	    #print "*** adding subfield '$subtag' to '$tag': ='$data'\n";
	    $current{$tag}->add_subfields($subtag => $data);
	}
    }

    my $rec = new MARC::Record();
    $rec->append_fields(@fields);

    return $rec->as_usmarc();
}


sub _format_grs1 {
    my($xml, $config) = @_;

    my $res = "";
    my $parser = new XML::LibXML();
    $parser->clean_namespaces(1);
    my $node = $parser->parse_string($xml)->documentElement();
    my $xc = XML::LibXML::XPathContext->new($node);
    $xc->registerNs(x => $node->namespaceURI());

    foreach my $field (@{ $config->{field} }) {
	my $xpath = $field->{xpath};
        foreach my $datanode ($xc->findnodes($xpath, $node)) {
	    my $data = _trim_nl($datanode->textContent);
	    next if !defined $data || $data eq "";
	    $data =~ s/\n/ /gs;
	    $res .= $field->{content} . " " . $data . "\n";
	}
    }

    return $res;
}


sub _format_sutrs {
    my($xml, $config) = @_;

    my $obj = XML::Simple::XMLin($xml, forceArray => 1);

    my @fields;
    if (defined $config) {
	# These are not really XPaths, despite the config-element name
	@fields = map { $_->{xpath} } @{ $config->{field} };
    } else {
	@fields = sort keys %$obj;
    }

    my $res = "";
    foreach my $name (@fields) {
	$res .= _format_sutrs_element(0, $name, $obj->{$name});
    }

    return $res;
}


sub _format_sutrs_element {
    my($level, $name, $value) = @_;

    if (ref $value && @$value == 1 && !ref $value->[0]) {
	# Cheat for single-element arrays.  This loses information,
	# but for SUTRS which is intended to be human-readable, it's a
	# good trade-off.
	$value = $value->[0];
    }

    if (!ref $value) {
	# I think this only happens for attributes (so usually namespaces)
	return ("\t" x $level) . "$name = " . _trim_nl($value) . "\n";
    }

    my $res = "\t" x $level . "$name = {\n";
    foreach my $val1 (@$value) {
	if (!ref $val1) {
	    $res .= "\t" x ($level+1) . _trim_nl($val1) . "\n";
	} else {
	    foreach my $subname (sort keys %$val1) {
		$res .= _format_sutrs_element($level+1, $subname,
					      $val1->{$subname});
	    }
	}
    }
    $res .= "\t" x $level . "}\n";
    return $res;
}


sub _trim_nl {
    my($text) = @_;
    $text =~ s/^\n+//s;
    $text =~ s/\n+$//s;
    return $text;
}


# The following code maps Z39.50 Type-1 queries to CQL by overriding
# the render() method on each query tree node type.

package Net::Z3950::RPN::Term;

sub _throw {
    return Koha::Solr::Z3950Service::_throw(@_);
}

sub _toCQL {
    my $self = shift;
    my($args, $defaultSet) = @_;
    my $gh = $args->{GHANDLE};
    my $field;
    my $relation;
    my($left_anchor, $right_anchor) = (0, 0);
    my($left_truncation, $right_truncation) = (0, 0);
    my $term = $self->{term};
    my $dbconfig = $gh->{cfg}->{database}->{$args->{DATABASES}->[0]};

    my $atts = $self->{attributes};
    untie $atts;

    # First we determine USE attribute
    foreach my $attr (@$atts) {
	my $set = $attr->{attributeSet};
	$set = $defaultSet if !defined $set;
	# Unknown attribute set (anything except BIB-1)
	_throw(121, $set) if $set ne '1.2.840.10003.3.1';
	if ($attr->{attributeType} == 1) {
	    my $val = $attr->{attributeValue};
	    $field = Koha::Solr::Z3950Service::_ap2index($dbconfig, $val);
	}
    }

    # Then we can handle any other attributes
    foreach my $attr (@$atts) {
        my $type = $attr->{attributeType};
        my $value = $attr->{attributeValue};

        if ($type == 2) {
	    # Relation.  The following switch hard-codes information
	    # about the crrespondance between the BIB-1 attribute set
	    # and CQL context set.
	    if ($value == 1) {
		$relation = "<";
	    } elsif ($value == 2) {
		$relation = "<=";
	    } elsif ($value == 3) {
		$relation = "=";
	    } elsif ($value == 4) {
		$relation = ">=";
	    } elsif ($value == 5) {
		$relation = ">";
	    } elsif ($value == 6) {
		$relation = "<>";
	    } elsif ($value == 100) {
		$relation = "=/phonetic";
	    } elsif ($value == 101) {
		$relation = "=/stem";
	    } elsif ($value == 102) {
		$relation = "=/relevant";
	    } else {
		_throw(117, $value);
	    }
        }

        elsif ($type == 3) { # Position
            if ($value == 1 || $value == 2) {
                $left_anchor = 1;
            } elsif ($value != 3) {
                _throw(119, $value);
            }
        }

        elsif ($type == 4) { # Structure -- we ignore it
        }

        elsif ($type == 5) { # Truncation
            if ($value == 1) {
                $right_truncation = 1;
            } elsif ($value == 2) {
                $left_truncation = 1;
            } elsif ($value == 3) {
                $right_truncation = 1;
                $left_truncation = 1;
            } elsif ($value == 101) {
		# Process # in search term
		$term =~ s/#/?/g;
            } elsif ($value == 104) {
		# Z39.58-style (CCL) truncation: #=single char, ?=multiple
		$term =~ s/#/?/g;
		$term =~ s/\?\d?/*/g;
            } elsif ($value != 100) {
                _throw(120, $value);
            }
        }

        elsif ($type == 6) { # Completeness
            if ($value == 2 || $value == 3) {
		$left_anchor = $right_anchor = 1;
	    } elsif ($value != 1) {
                _throw(122, $value);
            }
        }

        elsif ($type != 1) { # Unknown attribute type
            _throw(113, $type);
        }
    }

    $term = "*$term" if $left_truncation;
    $term = "$term*" if $right_truncation;
    $term = "^$term" if $left_anchor;
    $term = "$term^" if $right_anchor;

    $term = "\"$term\"" if $term =~ /[\s""\/=]/;

    if (defined $field && defined $relation) {
	$term = "$field $relation $term";
    } elsif (defined $field) {
	$term = "$field = $term";
    } elsif (defined $relation) {
	$term = "cql.serverChoice $relation $term";
    }

    return $term;
}

sub _toSolr {
    my $self = shift;
    my($args, $defaultSet) = @_;
    my $gh = $args->{GHANDLE};
    my $field;
    my($left_anchor, $right_anchor) = (0, 0);
    my($left_truncation, $right_truncation) = (0, 0);
    my $term = $self->{term};
    my $dbconfig = $gh->{cfg}->{database}->{$args->{DATABASES}->[0]};

    my $atts = $self->{attributes};
    untie $atts;

    # First we determine USE attribute
    foreach my $attr (@$atts) {
	my $set = $attr->{attributeSet};
	$set = $defaultSet if !defined $set;
	# Unknown attribute set (anything except BIB-1)
	_throw(121, $set) if $set ne '1.2.840.10003.3.1';
	if ($attr->{attributeType} == 1) {
	    my $val = $attr->{attributeValue};
	    $field = Koha::Solr::Z3950Service::_ap2index($dbconfig, $val);
	}
    }

    # Then we can handle any other attributes
    my $expr;
    foreach my $attr (@$atts) {
        my $type = $attr->{attributeType};
        my $value = $attr->{attributeValue};

        if ($type == 2) {
	    if ($value == 1) {
                $expr = "{* TO $term}";
	    } elsif ($value == 2) {
                $expr = "[* TO $term]";
	    } elsif ($value == 3) {
	    } elsif ($value == 4) {
                $expr = "[$term TO *]";
	    } elsif ($value == 5) {
                $expr = "{$term TO *}";
	    } else {
		_throw(117, $value);
	    }
        }

        elsif ($type == 3) { # Position
        }

        elsif ($type == 4) { # Structure -- we ignore it
        }

        elsif ($type == 5) { # Truncation
            if ($value == 1) {
                $right_truncation = 1;
            } elsif ($value == 2) {
                $left_truncation = 1;
            } elsif ($value == 3) {
                $right_truncation = 1;
                $left_truncation = 1;
            } elsif ($value == 101) {
		# Process # in search term
		$term =~ s/#/?/g;
            } elsif ($value == 104) {
		# Z39.58-style (CCL) truncation: #=single char, ?=multiple
		$term =~ s/#/?/g;
		$term =~ s/\?\d?/*/g;
            } elsif ($value != 100) {
                _throw(120, $value);
            }
        }

        elsif ($type != 1) { # Unknown attribute type
            _throw(113, $type);
        }
    }

    $term = "*$term" if $left_truncation;
    $term = "$term*" if $right_truncation;

    $term = qq{"$term"} if $term =~ /[\s""\/=]/;

    if (defined $field && defined $expr) {
       $term = "$field:$expr";
    } elsif (defined $field) {
       $term = "$field:$term";
    }

    return $term;
}

package Net::Z3950::RPN::RSID;
sub _toCQL {
    my $self = shift;
    my($args, $defaultSet) = @_;
    my $session = $args->{HANDLE};

    my $zid = $self->{id};
    my $rs = $session->{resultsets}->{$zid};
    _throw(128, $zid) if !defined $rs; # "Illegal result set name"

    my($zdbname, $dbconfig) =
	Koha::Solr::Z3950Service::_extract_database($args);
    my $method = $dbconfig->{resultsetid} || "fallback";

    my $sid = $rs->{rsid};
    return qq[cql.resultSetId="$sid"]
	if defined $sid && $method ne "search";

    return '(' . $rs->{qtext} . ')'
	if $method ne "id";

    # Error 18 is "Result set not supported as a search term"
    Koha::Solr::Z3950Service::_throw(18, $zid);
}

sub _toSolr {
    my $self = shift;
    my($args, $defaultSet) = @_;
    my $session = $args->{HANDLE};

    my $zid = $self->{id};
    my $rs = $session->{resultsets}->{$zid};
    _throw(128, $zid) if !defined $rs; # "Illegal result set name"

    my($zdbname, $dbconfig) =
	Koha::Solr::Z3950Service::_extract_database($args);
    my $method = $dbconfig->{resultsetid} || "fallback";

    my $sid = $rs->{rsid};
    return qq[solr.resultSetId="$sid"]
	if defined $sid && $method ne "search";

    return '(' . $rs->{qtext} . ')'
	if $method ne "id";

    # Error 18 is "Result set not supported as a search term"
    Koha::Solr::Z3950Service::_throw(18, $zid);
}

package Net::Z3950::RPN::And;
sub _toSolr {
    my $self = shift;
    my $left = $self->[0]->_toSolr(@_);
    my $right = $self->[1]->_toSolr(@_);
    return "($left AND $right)";
}

sub _toCQL {
    my $self = shift;
    my $left = $self->[0]->_toCQL(@_);
    my $right = $self->[1]->_toCQL(@_);
    return "($left and $right)";
}

package Net::Z3950::RPN::Or;
sub _toSolr {
    my $self = shift;
    my $left = $self->[0]->_toSolr(@_);
    my $right = $self->[1]->_toSolr(@_);
    return "($left OR $right)";
}

sub _toCQL {
    my $self = shift;
    my $left = $self->[0]->_toCQL(@_);
    my $right = $self->[1]->_toCQL(@_);
    return "($left or $right)";
}

package Net::Z3950::RPN::AndNot;
sub _toCQL {
    my $self = shift;
    my $left = $self->[0]->_toCQL(@_);
    my $right = $self->[1]->_toCQL(@_);
    return "($left not $right)";
}

sub _toSolr {
    my $self = shift;
    my $left = $self->[0]->_toSolr(@_);
    my $right = $self->[1]->_toSolr(@_);
    return "($left NOT $right)";
}


=head1 SEE ALSO

The C<simple2zoom> program.

The C<Koha::Solr::Z3950Service::Config> manual for the
configuration-file format.

The C<Net::Z3950::SimpleServer> module.

The C<ZOOM> module (in the C<Net::Z3950::ZOOM> distribution).

=head1 AUTHOR

Sebastian Hammer E<lt>quinn@indexdata.comE<gt>

Mike Taylor E<lt>mike@indexdata.comE<gt>

=head1 COPYRIGHT AND LICENCE

Copyright (C) 2007 by Index Data.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

1;
