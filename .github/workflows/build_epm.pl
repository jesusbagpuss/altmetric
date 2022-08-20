#!/usr/bin/env perl

# This gist claims to list default modules available on the ubuntu-latest runner.
# https://gist.github.com/JJ/edf3a39d68525439978da2a02763d42b
#
use File::Basename qw( basename );
use File::Find     qw( find );
use File::MimeInfo;

use POSIX qw( strftime );

use XML::LibXML;
use XML::LibXML::XPathContext;

use Digest::MD5;
use MIME::Base64 ();
#use MIME::Types; # not part of the default runner image, but File::MimeInfo is - so might as well use that.


use strict;
use feature qw(say);

use Data::Dumper;

# List files in this repo:
my $base_dir = $ENV{'GITHUB_WORKSPACE'} || '.';

my %skip = map { $_ => 1 } qw( .git .github .gitignore ); # ignore these files

# automatic build comment
my $gh_build_content = "This file was built with a GitHub action. Check the .github/workflows directory for more info!
Build details: - repo: " .$ENV{'GITHUB_REPOSITORY'} . " (branch: ". $ENV{'GITHUB_REF_NAME'}.")";

my $epmid;
my $epmi;
my $version;
my $output_epm;
my $lib_dir = "$base_dir/lib"; # EPMs get installed in there, but the <filename> elements in the epmi don't list this.

# This hash will hold the filenames that exist in the git repo.
# Values will be initalised with zeros. Files referenced in the epmi will be set to '1'
my $files = {};

find( {
        wanted => sub {
                if ( $skip{ basename( $File::Find::name) } ) {
                        $File::Find::prune = 1;
                        return;
                }
                # add if it's a file, not a dir
                if( -f $File::Find::name )
                {
                        # if it's the epm or epmi, we won't list it in the XML
                        if( $File::Find::name =~ m/\.epmi$/ )
                        {
                                #TODO - what if there are multiple EPMIs?
                                if( defined $epmi )
                                {
                                        # $epmi has been cached, but there's another!
                                        say "::warning file=$File::Find::name ::Multiple epmi files found. Using $epmi";
                                }
                                else
                                {
                                        $epmi = $File::Find::name;
                                }
                        }
                        elsif ( $File::Find::name =~ m/\.epm$/ )
                        {
                                #do we want to do anything special with the existing epm?
                                say "notice: file=$File::Find::name ::epm file already exists";
                        }
                        else
                        {
                                $files->{$_} = 0;
                        }
                }
        },
        no_chdir => 1 },
        $base_dir
);

if( !defined $epmi )
{
        say "::error ::No epmi file found";
        exit;
}

my $ns = 'epm';
my $ns_url = 'http://eprints.org/ep2/data/2.0';
my $epmi_xml = XML::LibXML->load_xml( location => $epmi );
my $xpc = XML::LibXML::XPathContext->new( $epmi_xml );
$xpc->registerNs( $ns => $ns_url );

my $epm = $epmi_xml->documentElement();

# Other elements that could/should exist?
# Might want to check these, or prompt for the empi to be updated?
# - creators + subfields
# - homepage
# - icon
# - controller (could look for an EPMC directory?)
# - documents + subfields
# - url

# These elements should be singular (and exist)
foreach my $elem (qw/ title description epmid requirements version /)
{
        my @nodes = $xpc->findnodes( "$ns:$elem", $epm );
        if( scalar @nodes < 1 )
        {
                say "::warning ::No $elem element found in epmi";
        }
        elsif( scalar @nodes > 1 )
        {
                say "::warning ::multiple $elem elements found in epmi";
        }
}

# already checked there's only one of these - just grab it now.
$epmid = $xpc->findvalue( "/$ns:epm/$ns:epmid" );
$version = $xpc->findvalue( "/$ns:epm/$ns:version" );

my @epmi_docs = $xpc->findnodes( "//$ns:documents/$ns:document" );
foreach my $epmi_doc (@epmi_docs)
{
        my $content = $xpc->findvalue( "$ns:content", $epmi_doc );

        if( !defined $content )
        {
                say "::warning ::document doesn't have content element";
        }
        elsif( $content eq 'coverimage' )
        {
                # validate coverimage
                my @nodes = $xpc->findnodes( "$ns:files/$ns:file", $epmi_doc );
                if( scalar @nodes != 1 )
                {
                        say "::warning ::incorrect files for 'coverimage' document";
                }
                else
                {
                        my $icon = $xpc->findvalue( "/$ns:epm/$ns:icon" ); #no context - from root
                        my $cover_filename = $xpc->findvalue( "$ns:filename", $nodes[0] );

                        # this feels a bit messy... but is accurate in a handful of test-cases
                        if( ( "static/$icon" eq $cover_filename ) && exists $files->{"$lib_dir/$cover_filename"}  )
                        {
                                $files->{"$lib_dir/$cover_filename"} = 1; #we've found a use for this file.
                                update_file_elements( $nodes[0], "$lib_dir/$cover_filename" );
                        }
                }
        }
        elsif( $content eq "install" )
        {
                my @nodes = $xpc->findnodes( "$ns:files/$ns:file", $epmi_doc );
                # There should be at least one file that is being added...
                if( scalar @nodes < 1 )
                {
                        say "::warning ::incorrect files for 'install' document";
                }
                else
                {
                        # sensible number of nodes
                        foreach my $file (@nodes)
                        {
                                my $filename = $xpc->findvalue( "$ns:filename", $file );
                                # files installed into archive config. These normally site in directories
                                # from the root of the git repo e.g. ./cgi/blah - this is listed in the
                                # epmi as epm/EPMID/cgi/blah
                                if( ( my $arc_filename = $filename ) =~ s!epm/$epmid/!! )
                                {
                                        $arc_filename = "$base_dir/$arc_filename";
                                        if( !exists $files->{$arc_filename} )
                                        {
                                                say "::warning ::file $filename not found in this repo";
                                        }
                                        else
                                        {
                                                $files->{$arc_filename} = 1;
                                                update_file_elements( $file, $arc_filename );
                                        }
                                }
                                elsif( !exists $files->{"$lib_dir/$filename"} )
                                {
                                        # file not found in git repo
                                        say "::warning ::file $filename not found in this repo";
                                }
                                else
                                {
                                        $files->{"$lib_dir/$filename"} = 1;
                                        update_file_elements( $file, "$lib_dir/$filename" );
                                }
                        }
                }
        }
        else
        {
                say "::warning ::Unrecognised content value '$content' for document";
        }

}

# update datestamp
my( $datestamp ) = $xpc->findnodes( "$ns:datestamp", $epm );
if( !defined $datestamp )
{
        $datestamp = $epm->addNewChild( $ns_url, "datestamp" );
}
else
{
        $datestamp->removeChildNodes;
}

$datestamp->appendText( value_datestamp() );

# add comment about build action
my $fc = $epm->firstChild;
my $gh_build = XML::LibXML::Comment->new( $gh_build_content );

$epm->insertBefore( $gh_build, $fc );
my $output_file = "$base_dir/$epmid-$version-github_action.epm";
say "::notice ::Saving to: $output_file";

open my $xml, '>' , $output_file or die "Cannot write: $!\n";
print $xml $epmi_xml->toString(2);
close $xml;


sub update_file_elements
{
        my( $node, $real_path ) = @_;
        # sub-elements:
        # - datasetid (document)
        # - filename
        # - mime_type
        # - hash
        # - hash_type (MD5)
        # - filesize
        # - <data encoding='base64'>...</data>

        use bytes;
        open(my $fh, "<", $real_path) or die "Error opening $real_path: $!";
        sysread($fh, my $data, -s $fh);
        close($fh);

        foreach my $child (qw/ datasetid mime_type hash hash_type filesize data /)
        {
                my $fn = "value_$child";
                my $sub_ref = \&$fn;

                my( $child_node ) = $xpc->findnodes( "$ns:$child", $node );

                if( !defined $child_node )
                {
                        $child_node = $node->addNewChild( $ns_url, $child );
                }
                else
                {
                        $child_node->removeChildNodes;
                }
                $child_node->appendText( &$sub_ref( $data, $real_path ) );
                if( $child eq "data" )
                {
                        $child_node->setAttribute( 'encoding', 'base64' );
                }
        }
}


sub value_data
{
        my( $data ) = @_;

        return MIME::Base64::encode_base64( $data )
}

sub value_datasetid
{
        return "document";
}

sub value_filesize
{
        my( $data ) = @_;

        return length( $data );
}
sub value_hash
{
        my( $data ) = @_;

        return Digest::MD5::md5_hex( $data );
        #open ( myd $fh, '<', $filename ) or die "Can't open '$filename': $!";
        #binmode ( $fh );

        #return Digest::MD5->new->addfile( $fh )->hexdigest
}

sub value_hash_type
{
        return "MD5";
}

sub value_mime_type
{
        my( $data, $filename ) = @_;

        # this works on file extensions. Some files e.g. cgi scripts don't have an extension,
        # so we set a default
        #return MIME::Types->new->mimeTypeOf( $filename ) || 'text/plain';
        return mimetype( $filename );
}

sub value_datestamp
{
        return strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime( time() ) );
}
