package Config::Model::Tester;
# ABSTRACT: Test framework for Config::Model

use warnings;
use strict;
use locale;
use utf8;
use 5.10.1;

use Test::More;
use Log::Log4perl 1.11 qw(:easy :levels);
use Path::Tiny;
use File::Copy::Recursive qw(fcopy rcopy dircopy);

use Test::Warn;
use Test::Exception;
use Test::File::Contents ;
use Test::Differences;
use Test::Memory::Cycle ;

# use eval so this module does not have a "hard" dependency on Config::Model
# This way, Config::Model can build-depend on Config::Model::Tester without
# creating a build dependency loop.
eval {
    require Config::Model;
    require Config::Model::Lister;
    require Config::Model::Value;
    require Config::Model::BackendMgr;
} ;

use vars qw/$model $conf_file_name $conf_dir $model_to_test $home_for_test @tests $skip @ISA @EXPORT/;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(run_tests);

$File::Copy::Recursive::DirPerms = 0755;

sub setup_test {
    my ( $app_to_test, $t_name, $wr_root, $trace, $setup ) = @_;

    # cleanup before tests
    $wr_root->remove_tree();
    $wr_root->mkpath( { mode => 0755 } );

    $conf_dir =~ s!~/!$home_for_test/! if $conf_dir;

    my $wr_dir    = $wr_root->child('test-' . $t_name);
    my $wr_dir2   = $wr_root->child('test-' . $t_name.'-w');
    my $conf_file ;
    $conf_file = $wr_dir->child($conf_dir,$conf_file_name)
        if $conf_dir and $conf_file_name;

    my $ex_dir = path('t')->child('model_tests.d', "$app_to_test-examples");
    my $ex_data = $ex_dir->child($t_name);

    my @file_list;

    if ($setup) {
        foreach my $file (keys %$setup) {
            my $map = $setup->{$file} ;
            my $destination_str
                = ref ($map) eq 'HASH' ? $map->{$^O} // $map->{default}
                :                        $map;
            if (not defined $destination_str) {
                die "$app_to_test $t_name setup error: cannot find destination for test file $file" ;
            }
            $destination_str =~ s!~/!$home_for_test/!;
            my $destination = $wr_dir->child($destination_str) ;
            $destination->parent->mkpath( { mode => 0755 }) ;
            my $data_file = $ex_data->child($file);
            die "cannot find $data_file" unless $data_file->exists;
            my $data = $data_file->slurp() ;
            $destination->spew( $data );
            @file_list = list_test_files ($wr_dir);
        }
    }
    elsif ( $ex_data->is_dir ) {
        # copy whole dir
        my $destination_dir = $conf_dir ? $wr_dir->child($conf_dir) : $wr_dir ;
        $destination_dir->mkpath( { mode => 0755 });
        say "dircopy ". $ex_data->stringify . '->'. $destination_dir->stringify
            if $trace ;
        dircopy( $ex_data->stringify, $destination_dir->stringify )
          || die "dircopy $ex_data -> $destination_dir failed:$!";
        @file_list = list_test_files ($destination_dir);
    }
    elsif ( $ex_data->exists ) {
        # either one if true if $conf_file is undef
        die "test data is missing \$conf_dir" unless defined $conf_dir;
        die "test data is missing \$conf_file" unless defined $conf_file;

        # just copy file
        say "file copy ". $ex_data->stringify . '->'. $conf_file->stringify
            if $trace ;
        fcopy( $ex_data->stringify, $conf_file->stringify )
          || die "copy $ex_data -> $conf_file failed:$!";
    }
    else {
        note ('starting test without original config data, i.e. from scratch');
    }
    ok( 1, "Copied $app_to_test example $t_name" );

    return ( $wr_dir, $wr_dir2, $conf_file, $ex_data, @file_list );
}

#
# New subroutine "list_test_files" extracted - Thu Nov 17 17:27:20 2011.
#
sub list_test_files {
    my $debian_dir = shift;
    my @file_list ;

    my $iter = $debian_dir->iterator({ recurse => 1 });
    my $debian_str = $debian_dir->stringify;

	while ( my $child = $iter->() ) {
		next if $child->is_dir ;

		push @file_list, '/' . $child->relative($debian_str)->stringify;
		#push @file_list, '/'.join('/',@l) ; # build a unix-like path even on windows
	};

    return sort @file_list;
}

sub write_config_file {
    my ($conf_dir,$wr_dir,$t) = @_;

    if ($t->{config_file}) {
        my $file = $conf_dir ? "$conf_dir/" : '';
        $file .= $t->{config_file} ;
        $wr_dir->child($file)->parent->mkpath({mode => 0755} ) ;
    }
}

sub check_load_warnings {
    my ($root,$t) = @_ ;

    if ( ($t->{no_warnings} or exists $t->{load_warnings}) and not defined $t->{load_warnings}) {
        local $Config::Model::Value::nowarning = 1;
        $root->init;
        ok( 1,"Read configuration and created instance with init() method without warning check" );
    }
    else {
        warnings_like { $root->init; } $t->{load_warnings},
            "Read configuration and created instance with init() method with warning check ";
    }
}

sub run_update {
    my ($inst, $dir, $t) = @_;
    my %args = %{$t->{update}};

    my $ret = delete $args{returns};

    local $Config::Model::Value::nowarning = $args{no_warnings} || $t->{no_warnings} || 0;

    note("updating config with ". join(' ',%args));
    my $res = $inst->update( from_dir => $dir, %args ) ;
    if (defined $ret) {
        is($res,$ret,"updated configuration, got expected return value");
    }
    else {
        ok(1,"updated configuration");
    }
}

sub load_instructions {
    my ($root,$t,$trace) = @_ ;

    print "Loading $t->{load}\n" if $trace ;
    $root->load( $t->{load} );
    ok( 1, "load called" );
}

sub apply_fix {
    my $inst = shift;
    local $Config::Model::Value::nowarning = 1;
    $inst->apply_fixes;
    ok( 1, "apply_fixes called" );
}

sub dump_tree {
    my ($app_to_test, $root, $mode, $no_warnings, $t, $trace) = @_;

    print "dumping tree ...\n" if $trace;
    my $dump  = '';
    my $risky = sub {
        $dump = $root->dump_tree( mode => $mode );
    };

    if ( defined $t->{dump_errors} ) {
        my $nb = 0;
        my @tf = @{ $t->{dump_errors} };
        while (@tf) {
            my $qr = shift @tf;
            throws_ok { &$risky } $qr, "Failed dump $nb of $app_to_test config tree";
            my $fix = shift @tf;
            $root->load($fix);
            ok( 1, "Fixed error nb " . $nb++ );
        }
    }

    if ( ($no_warnings or (exists $t->{dump_warnings}) and not defined $t->{dump_warnings}) ) {
        local $Config::Model::Value::nowarning = 1;
        &$risky;
        ok( 1, "Ran dump_tree (no warning check)" );
    }
    else {
        warnings_like { &$risky; } $t->{dump_warnings}, "Ran dump_tree";
    }
    ok( $dump, "Dumped $app_to_test config tree in $mode mode" );

    print $dump if $trace;
    return $dump;
}

# TODO: factorise with function above and create parameters to
# handle warnings in both cases with warnings_like
sub dump_tree_custom_mode {
    my ($label, $root, $t, $trace) = @_;

    local $Config::Model::Value::nowarning = $t->{no_warnings} || 0;

    my $dump = $root->dump_tree();
    ok( $dump, "Dumped $label config tree in custom mode" );
    return $dump;
}

sub check_data {
    my ($label, $root, $c, $nw) = @_;

    local $Config::Model::Value::nowarning = $nw || 0;
    my @checks = ref $c eq 'ARRAY' ? @$c
        : map { ( $_ => $c->{$_})} sort keys %$c ;

    while (@checks) {
        my $path       = shift @checks;
        my $v          = shift @checks;
        my $check_v    = ref $v eq 'HASH' ? delete $v->{value} : $v;
        my @check_args = ref $v eq 'HASH' ? %$v : ();
        my $check_str  = @check_args ? " (@check_args)" : '';
        my $obj = $root->grab( step => $path, type => ['leaf','check_list'], @check_args );
        my $got = $obj->fetch(@check_args);
        if (ref $check_v eq 'Regexp') {
            like( $got, $check_v, "$label check '$path' value with regexp$check_str" );
        }
        else {
            is( $got, $check_v, "$label check '$path' value$check_str" );
        }
    }
}

sub check_annotation {
    my ($root, $t) = @_;

    my $annot_check = $t->{verify_annotation};
    foreach my $path (keys %$annot_check) {
        my $note = $annot_check->{$path};
        is( $root->grab($path)->annotation, $note, "check $path annotation" );
    }
}

sub has_key {
    my ($root, $c, $nw) = @_;

    _test_key($root, $c, $nw, 0);
}

sub has_not_key {
    my ($root, $c, $nw) = @_;

    _test_key($root, $c, $nw, 1);
}

sub _test_key {
    my ($root, $c, $nw, $invert) = @_;

    my @checks = ref $c eq 'ARRAY' ? @$c
        : map { ( $_ => $c->{$_})} sort keys %$c ;

    while (@checks) {
        my $path       = shift @checks;
        my $spec       = shift @checks;
        my @key_checks = ref $spec eq 'ARRAY' ? @$spec: ($spec);

        my $obj = $root->grab( step => $path, type => 'hash' );
        my @keys = $obj->fetch_all_indexes;
        my $res = 0;
        foreach my $check (@key_checks) {
            my @match  ;
            foreach my $k (@keys) {
                if (ref $check eq 'Regexp') {
                    push @match, $k if $k =~ $check;
                }
                else {
                    push @match, $k if $k eq $check;
                }
            }
            if ($invert) {
                is(scalar @match,0, "check $check matched no key" );
            }
            else {
                ok(scalar @match, "check $check matched with keys @match" );
            }
        }
    }
}

sub write_data_back {
    my ($app_to_test, $inst, $t) = @_;
    local $Config::Model::Value::nowarning = $t->{no_warnings} || 0;
    $inst->write_back( force => 1 );
    ok( 1, "$app_to_test write back done" );
}

sub check_file_content {
    my ($wr_dir, $t) = @_;

    if (my $fc = $t->{file_contents} || $t->{file_content}) {
        foreach my $f (keys %$fc) {
            my $t = $fc->{$f} ;
            my @tests = ref $t eq 'ARRAY' ? @$t : ($t) ;
            foreach my $subtest (@tests) {
                file_contents_eq_or_diff $wr_dir->child($f)->stringify,  $subtest,
                    "check that $f contains $subtest";
            }
        }
    }

    if (my $fc = $t->{file_contents_like}) {
        foreach my $f (keys %$fc) {
            my $t = $fc->{$f} ;
            my @tests = ref $t eq 'ARRAY' ? @$t : ($t) ;
            foreach my $subtest (@tests) {
                file_contents_like $wr_dir->child($f)->stringify,  $subtest,
                    "check that $f matches regexp $subtest";
            }
        }
    }

    if (my $fc = $t->{file_contents_unlike}) {
        foreach my $f (keys %$fc) {
            my $t = $fc->{$f} ;
            my @tests = ref $t eq 'ARRAY' ? @$t : ($t) ;
            foreach my $subtest (@tests) {
                file_contents_unlike $wr_dir->child($f)->stringify,  $subtest,
                    "check that $f does not match regexp $subtest";
            }
        }
    }
}

sub check_added_or_removed_files {
    my ( $conf_dir, $wr_dir, $t, @file_list) = @_;

    # copy whole dir
    my $destination_dir
        = $t->{setup} ? $wr_dir
        : $conf_dir   ? $wr_dir->child($conf_dir)
        :               $wr_dir ;
    my @new_file_list = list_test_files($destination_dir) ;
    $t->{file_check_sub}->( \@file_list ) if defined $t->{file_check_sub};
    eq_or_diff( \@new_file_list, [ sort @file_list ], "check added or removed files" );
}

sub create_second_instance {
    my ($app_to_test, $t_name, $wr_dir, $wr_dir2,$t, $config_dir_override) = @_;

    # create another instance to read the conf file that was just written
    dircopy( $wr_dir->stringify, $wr_dir2->stringify )
        or die "can't copy from $wr_dir to $wr_dir2: $!";

    my $i2_test = $model->instance(
        root_class_name => $model_to_test,
        root_dir        => $wr_dir2->stringify,
        config_file     => $t->{config_file} ,
        instance_name   => "$app_to_test-$t_name-w",
        application     => $app_to_test,
        check           => $t->{load_check2} || 'yes',
        config_dir      => $config_dir_override,
    );

    ok( $i2_test, "Created instance $app_to_test-test-$t_name-w" );

    local $Config::Model::Value::nowarning = $t->{no_warnings} || 0;
    my $i2_root = $i2_test->config_root;
    $i2_root->init;

    return $i2_root;
}

sub run_model_test {
    my ($app_to_test, $app_to_test_conf, $do, $model, $trace, $wr_root) = @_ ;

    $skip = 0;
    undef $conf_file_name ;
    undef $conf_dir ;
    undef $home_for_test ;

    note("Beginning $app_to_test test ($app_to_test_conf)");

    unless ( my $return = do $app_to_test_conf ) {
        warn "couldn't parse $app_to_test_conf: $@" if $@;
        warn "couldn't do $app_to_test_conf: $!" unless defined $return;
        warn "couldn't run $app_to_test_conf" unless $return;
    }

    if ($skip) {
        note("Skipped $app_to_test test ($app_to_test_conf)");
        return;
    }

    my ($trash, $appli_info, $applications) = Config::Model::Lister::available_models(1);

    # even undef, this resets the global variable there
    Config::Model::BackendMgr::_set_test_home($home_for_test) ;

    if (not defined $model_to_test) {
        $model_to_test = $applications->{$app_to_test};
        if (not defined $model_to_test) {
            my @k = sort values %$applications;
            my @files = map { $_->{_file} // 'unknown' } values %$appli_info ;
            die "Cannot find model name for $app_to_test in files >@files<. Know dev models are >@k<. ".
                "Check your test name (the file ending with -test-conf.pl) or set the \$model_to_test global variable\n";
        }
    }

    my $config_dir_override = $appli_info->{$app_to_test}{config_dir}; # may be undef

    my $note ="$app_to_test uses $model_to_test model";
    $note .= " on file $conf_file_name" if defined $conf_file_name;
    note($note);

    my $idx = 0;
    foreach my $t (@tests) {
        translate_test_data($t);
        my $t_name = $t->{name} || "t$idx";
        if ( defined $do and $t_name !~ /$do/) {
            $idx++;
            next;
        }
        note("Beginning subtest $app_to_test $t_name");

        my ($wr_dir, $wr_dir2, $conf_file, $ex_data, @file_list)
            = setup_test ($app_to_test, $t_name, $wr_root,$trace, $t->{setup});

        write_config_file($conf_dir,$wr_dir,$t);

        my $inst = $model->instance(
            root_class_name => $model_to_test,
            root_dir        => $wr_dir->stringify,
            instance_name   => "$app_to_test-" . $t_name,
            application     => $app_to_test,
            config_file     => $t->{config_file} ,
            check           => $t->{load_check} || 'yes',
            config_dir      => $config_dir_override,
        );

        my $root = $inst->config_root;

        check_load_warnings ($root,$t);

        run_update($inst,$wr_dir,$t) if $t->{update};

        load_instructions ($root,$t,$trace) if $t->{load} ;

        apply_fix($inst) if  $t->{apply_fix};

        dump_tree ($app_to_test, $root, 'full', $t->{no_warnings}, $t->{full_dump}, $trace) ;

        my $dump = dump_tree_custom_mode ($app_to_test, $root, $t, $trace) ;

        check_data("first", $root, $t->{check}, $t->{no_warnings}) if $t->{check};

        has_key     ( $root, $t->{has_key}, $t->{no_warnings}) if $t->{has_key} ;
        has_not_key ( $root, $t->{has_not_key}, $t->{no_warnings}) if $t->{has_not_key} ;

        check_annotation($root,$t) if $t->{verify_annotation};

        write_data_back ($app_to_test, $inst, $t) ;

        check_file_content($wr_dir,$t) ;

        check_added_or_removed_files ($conf_dir, $wr_dir, $t, @file_list) if $ex_data->is_dir;

        my $i2_root = create_second_instance ($app_to_test, $t_name, $wr_dir, $wr_dir2,$t, $config_dir_override);

        my $p2_dump = dump_tree_custom_mode("second $app_to_test", $i2_root, $t) ;

        unified_diff;
        eq_or_diff(
            [ split /\n/,$p2_dump ],
            [ split /\n/,$dump ],
            "compare original $app_to_test custom data with 2nd instance custom data",
        );

        ok( -s "$wr_dir2/$conf_dir/$conf_file_name" ,
            "check that original $app_to_test file was not clobbered" )
                if defined $conf_file_name ;

        check_data("second", $i2_root, $t->{wr_check}, $t->{no_warnings}) if $t->{wr_check} ;

        note("End of subtest $app_to_test $t_name");

        $idx++;
    }
    note("End of $app_to_test test");

}

sub translate_test_data {
    my $t = shift;
    map {$t->{full_dump}{$_} = delete $t->{$_} if $t->{$_}; } qw/dump_warnings dump_errors/;
}

sub run_tests {
    my ( $arg, $test_only_app, $do ) = @_;

    my $log = 0;

    my $trace = ($arg =~ /t/) ? 1 : 0;
    $log  = 1 if $arg =~ /l/;

    my $log4perl_user_conf_file = ($ENV{HOME} || '') . '/.log4config-model';

    if ( $log and -e $log4perl_user_conf_file ) {
        Log::Log4perl::init($log4perl_user_conf_file);
    }
    else {
        Log::Log4perl->easy_init( $log ? $WARN : $ERROR );
    }

    eval { $model = Config::Model->new(); } ;
    if ($@) {
        plan skip_all => 'Config::Model is not loaded' ;
        return;
    }

    Config::Model::Exception::Any->Trace(1) if $arg =~ /e/;

    ok( 1, "compiled" );

    # pseudo root where config files are written by config-model
    my $wr_root = path('wr_root');

    my @group_of_tests = grep { /-test-conf.pl$/ } glob("t/model_tests.d/*");

    foreach my $app_to_test_conf (@group_of_tests) {
        my ($app_to_test) = ( $app_to_test_conf =~ m!\.d/([\w\-]+)-test-conf! );
        next if ( $test_only_app and $test_only_app ne $app_to_test ) ;
        run_model_test($app_to_test, $app_to_test_conf, $do, $model, $trace, $wr_root) ;
    }

    memory_cycle_ok($model,"test memory cycle") ;

    done_testing;

}
1;

=head1 SYNOPSIS

 # in t/model_test.t
 use warnings;
 use strict;

 use Config::Model::Tester ;
 use ExtUtils::testlib;

 my $arg = shift || ''; # typically e t l
 my $test_only_app = shift || ''; # only run one set of test
 my $do = shift ; # select subtests to run with a regexp

 run_tests($arg, $test_only_app, $do) ;

=head1 DESCRIPTION

This class provides a way to test configuration models with tests files.
This class was designed to tests several models and several tests
cases per model.

A specific layout for test files must be followed.

=head2 Simple test file layout

Each test case is represented by a configuration file (not
a directory) in the C<*-examples> directory. This configuration file
will be used by the model to test and is copied as
C<$confdir/$conf_file_name> using the global variables explained
below.

In the example below, we have 1 app model to test: C<lcdproc> and 2 tests
cases. The app name matches the file specified in
C<lib/Config/Model/*.d> directory. In this case, the app name matches
C<lib/Config/Model/system.d/lcdproc>

 t
 |-- model_test.t
 \-- model_tests.d           # do not change directory name
     |-- lcdproc-test-conf.pl   # test specification for lcdproc app
     \-- lcdproc-examples
         |-- t0              # subtest t0
         \-- LCDD-0.5.5      # subtest for older LCDproc

Test specification is written in C<lcdproc-test-conf.pl> file (i.e. this
modules looks for files named  like C<< <app-name>-test-conf.pl> >>).

Subtests are specified in files in directory C<lcdproc-examples> (
i.e. this modules looks for subtests in directory
C<< <model-name>-examples.pl> >>. C<lcdproc-test-conf.pl> contains
instructions so that each file will be used as a C</etc/LCDd.conf>
file during each test case.

C<lcdproc-test-conf.pl> can contain specifications for more test
cases. Each test case will require a new file in C<lcdproc-examples>
directory.

See L</Examples> for a link to the actual LCDproc model tests

=head2 Test file layout for multi-file configuration

When a configuration is spread over several files, each test case is
provided in a sub-directory. This sub-directory is copied in
C<$conf_dir> (a global variable as explained below)

In the example below, the test specification is written in
C<dpkg-test-conf.pl>. Dpkg layout requires several files per test case.
C<dpkg-test-conf.pl> will contain instructions so that each directory
under C<dpkg-examples> will be used.

 t/model_tests.d
 \-- dpkg-test-conf.pl         # test specification
 \-- dpkg-examples
     \-- libversion            # example subdir, used as subtest name
         \-- debian            # directory for one test case
             |-- changelog
             |-- compat
             |-- control
             |-- copyright
             |-- rules
             |-- source
             |   \-- format
             \-- watch


See L</Examples> for a link to the (many) Dpkg model tests

=head2 More complex file layout

Each test case is a sub-directory on the C<*-examples> directory and
contains several files. The destination of the test files may depend
on the system (e.g. the OS). For instance, system wide C<ssh_config>
is stored in C</etc/ssh> on Linux, and directly in C</etc> on MacOS.

These files are copied in a test directory using a C<setup> parameter:

  setup => {
    test_file_in_example_dir => 'destination'
  }

Let's consider this example of 2 tests cases for ssh:

 t/model_tests.d/
 |-- ssh-test-conf.pl
 |-- ssh-examples
     \-- basic
         |-- system_ssh_config
         \-- user_ssh_config


Unfortunately, C<user_ssh_config> is a user file, so you specify where
the home directory for the tests with another global variable:

  $home_for_test = '/home/joe' ;

For Linux only, the C<setup> parameter is:

 setup => {
   'system_ssh_config' => '/etc/ssh/ssh_config',
   'user_ssh_config'   => "~/.ssh/config"
 }

On the other hand, system wide config file is different on MacOS and
the test file must be copied in the correct location. When the value
of the C<setup> hash is another hash, the key of this other hash is
used as to specify the target location for other OS (as returned by
Perl C<$^O> variable:

      setup => {
        'system_ssh_config' => {
            'darwin' => '/etc/ssh_config',
            'default' => '/etc/ssh/ssh_config',
        },
        'user_ssh_config' => "~/.ssh/config"
      }


See the actual L<Ssh and Sshd model tests|https://github.com/dod38fr/config-model-openssh/tree/master/t/model_tests.d>

=head2 Basic test specification

Each model test is specified in C<< <model>-test-conf.pl >>. This file
contains a set of global variables. (yes, global variables are often bad ideas
in programs, but they are handy for tests):

 # config file name (used to copy test case into test wr_root directory)
 $conf_file_name = "fstab" ;
 # config dir where to copy the file (optional)
 #$conf_dir = "etc" ;
 # home directory for this test
 $home_for_test = '/home/joe' ;

Here, C<t0> file will be copied in C<wr_root/test-t0/etc/fstab>.

 # config model name to test
 $model_to_test = "Fstab" ;

 # list of tests. This modules looks for @tests global variable
 @tests = (
    {
     # test name
     name => 't0',
     # add optional specification here for t0 test
    },
    {
     name => 't1',
     # add optional specification here for t1 test
    },
 );

 1; # to keep Perl happy

You can suppress warnings by specifying C<< no_warnings => 1 >>. On
the other hand, you may also want to check for warnings specified to
your model. In this case, you should avoid specifying C<no_warnings>
here and specify warning tests or warning filters as mentioned below.

See actual L<fstab test|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/fstab-test-conf.pl>.

=head2 Internal tests or backend tests

Some tests will require the creation of a configuration class dedicated
for test (typically to test corner cases on a backend).

This test class can be created directly in the test specification
by calling L<create_config_class|Config::Model/create_config_class> on
C<$model> variable. See for instance the
L<layer test|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/layer-test-conf.pl>
or the
L<test for shellvar backend|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/backend-shellvar-test-conf.pl>.

=head2 Test specification with arbitrary file names

In some models (e.g. C<Multistrap>, the config file is chosen by the user.
In this case, the file name must be specified for each tests case:

 $model_to_test = "Multistrap";

 @tests = (
    {
        name        => 'arm',
        config_file => '/home/foo/my_arm.conf',
        check       => {},
    },
 );


See actual L<multistrap test|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/multistrap-test-conf.pl>.

=head2 Test scenario

Each subtest follow a sequence explained below. Each step of this
sequence may be altered by adding specification in
C<< <model-to-test>-test-conf.pl >>:

=over

=item *

Setup test in C<< wr_root/<subtest name>/ >>. If your configuration file layout depend
on the target system, you will have to specify the path using C<setup> parameter.
See L</"Test file layout depending on system">.

=item *

Create configuration instance, load config data and check its validity. Use
C<< load_check => 'no' >> if your file is not valid.

=item *

Check for config data warning. You should pass the list of expected warnings.
E.g.

    load_warnings => [ qr/Missing/, (qr/deprecated/) x 3 , ],

Use an empty array_ref to mask load warnings.

=item *

Optionally run L<update|App::Cme::Command::update> command:

    update => { in => 'some-test-data.txt', returns => 'foo' , no_warnings => [ 0 | 1 ] }

C<returns> is the expected return value (optional). All other
arguments are passed to C<update> method. Note that C<< quiet => 1 >>
may be useful for less verbose test.

=item *

Optionally load configuration data. You should design this config data to
suppress any error or warning mentioned above. E.g:

    load => 'binary:seaview Synopsis="multiplatform interface for sequence alignment"',

See L<Config::Model::Loader> for the syntax of the string accepted by C<load> parameter.

=item *

Optionally, call L<apply_fixes|Config::Model::Instance/apply_fixes>:

    apply_fix => 1,

=item *

Call L<dump_tree|Config::Model::Node/dump_tree ( ... )> to check the validity of the
data after optional C<apply_fix>. This step is not optional.

Use C<dump_errors> if you expect issues:

  full_dump => {
    dump_errors =>  [
        # the issues     the fix that will be applied
        qr/mandatory/ => 'Files:"*" Copyright:0="(c) foobar"',
        qr/mandatory/ => ' License:FOO text="foo bar" ! Files:"*" License short_name="FOO" '
    ],
  }

Likewise, specify any expected warnings (note the list must contain only C<qr> stuff):

  full_dump => {
        dump_warnings => [ (qr/deprecated/) x 3 ],
  }

You can tolerate any dump warning this way:

  full_dump => {
        dump_warnings => undef ,
  }

Both C<dump_warnings> and C<dump_errors> can be specified in C<full_dump> hash.

=item *

Run specific content check to verify that configuration data was retrieved
correctly:

    check => {
        'fs:/proc fs_spec',           "proc" ,
        'fs:/proc fs_file',           "/proc" ,
        'fs:/home fs_file',          "/home",
    },

The keys of the hash points to the value to be checked using the
syntax described in L<Config::Model::AnyThing:/"grab(...)">.

You can run check using different check modes (See L<Config::Model::Value/"fetch( ... )">)
by passing a hash ref instead of a scalar :

    check  => {
        'sections:debian packages:0' , { mode => 'layered', value => 'dpkg-dev' },
        'sections:base packages:0',    { mode => 'layered', value => "gcc-4.2-base' },
    },

The whole hash content (except "value") is passed to  L<grab|Config::Model::AnyThing/"grab(...)">
and L<fetch|Config::Model::Value/"fetch( ... )">

A regexp can also be used to check value:

   check => {
      "License text" => qr/gnu/i,
      "License text" => { mode => 'custom', value => qr/gnu/i },
   }

=item *

Verify if a hash contains one or more keys (or keys matching a regexp):

 has_key => [
    'sections' => 'debian', # sections must point to a hash element
    'control' => [qw/source binary/],
    'copyright Files' => qr/.c$/,
    'copyright Files' => [qr/\.h$/], qr/\.c$/],
 ],

=item *

Verify that a hash has B<not> a key (or a key matching a regexp):

 has_not_key => [
    'copyright Files' => qr/.virus$/ # silly, isn't ?
 ],

=item *

Verify annotation extracted from the configuration file comments:

    verify_annotation => {
            'source Build-Depends' => "do NOT add libgtk2-perl to build-deps (see bug #554704)",
            'source Maintainer' => "what a fine\nteam this one is",
        },


=item *

Write back the config data in C<< wr_root/<subtest name>/ >>.
Note that write back is forced, so the tested configuration files are
written back even if the configuration values were not changed during the test.

You can skip warning when writing back with the global :

    no_warnings => 1,

=item *

Check the content of the written files(s) with L<Test::File::Contents>. Tests can be grouped
in an array ref:

   file_contents => {
            "/home/foo/my_arm.conf" => "really big string" ,
            "/home/bar/my_arm.conf" => [ "really big string" , "another"], ,
        }

   file_contents_like => {
            "/home/foo/my_arm.conf" => [ qr/should be there/, qr/as well/ ] ,
   }

   file_contents_unlike => {
            "/home/foo/my_arm.conf" => qr/should NOT be there/ ,
   }

=item *

Check added or removed configuration files. If you expect changes,
specify a subref to alter the file list:

    file_check_sub => sub {
        my $list_ref = shift ;
        # file added during tests
        push @$list_ref, "/debian/source/format" ;
    },

=item *

Copy all config data from C<< wr_root/<subtest name>/ >>
to C<< wr_root/<subtest name>-w/ >>. This steps is necessary
to check that configuration written back has the same content as
the original configuration.

=item *

Create another configuration instance to read the conf file that was just copied
(configuration data is checked.)

=item *

You can skip the load check if the written file still contain errors (e.g.
some errors were ignored and cannot be fixed) with C<< load_check2 => 'no' >>

=item *

Compare data read from original data.

=item *

Run specific content check on the B<written> config file to verify that
configuration data was written and retrieved correctly:


    wr_check => {
        'fs:/proc fs_spec' =>          "proc" ,
        'fs:/proc fs_file' =>          "/proc",
        'fs:/home fs_file' =>          "/home",
    },

Like the C<check> item explained above, you can run C<wr_check> using
different check modes.

=back

=head2 Running the test

Run all tests with one of these commands:

 prove -l t/model_test.t :: [ t|l|e [ <model_name> [ <regexp> ]]]
 perl -Ilib t/model_test.t  [ t|l|e [ <model_name> [ <regexp> ]]]

By default, all tests are run on all models.

You can pass arguments to C<t/model_test.t>:

=over

=item *

a bunch of letters. 't' to get test traces. 'e' to get stack trace in case of
errors, 'l' to have logs. All other letters are ignored. E.g.

  # run with log and error traces
  prove -lv t/model_test.t :: el

=item *

The model name to tests. E.g.:

  # run only fstab tests
  prove -lv t/model_test.t :: x fstab

=item *

A regexp to filter subtest E.g.:

  # run only fstab tests foobar subtest
  prove -lv t/model_test.t :: x fstab foobar

  # run only fstab tests foo subtest
  prove -lv t/model_test.t :: x fstab '^foo$'

=back

=head1 Examples

=over

=item *

L<LCDproc|http://lcdproc.org> has a single configuration file:
C</etc/LCDd.conf>. Here's LCDproc test
L<layout|https://github.com/dod38fr/config-model-lcdproc/tree/master/t/model_tests.d>
and the L<test specification|https://github.com/dod38fr/config-model-lcdproc/blob/master/t/model_tests.d/lcdd-test-conf.pl>

=item *

Dpkg packages are constructed from several files. These files are handled like
configuration files by L<Config::Model::Dpkg>. The
L<test layout|http://anonscm.debian.org/gitweb/?p=pkg-perl/packages/libconfig-model-dpkg-perl.git;a=tree;f=t/model_tests.d;hb=HEAD>
features test with multiple file in
L<dpkg-examples|http://anonscm.debian.org/gitweb/?p=pkg-perl/packages/libconfig-model-dpkg-perl.git;a=tree;f=t/model_tests.d/dpkg-examples;hb=HEAD>.
The test is specified in L<dpkg-test-conf.pl|http://anonscm.debian.org/gitweb/?p=pkg-perl/packages/libconfig-model-dpkg-perl.git;a=blob_plain;f=t/model_tests.d/dpkg-test-conf.pl;hb=HEAD>

=item *

L<multistrap-test-conf.pl|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/multistrap-test-conf.pl>
and L<multistrap-examples|https://github.com/dod38fr/config-model/tree/master/t/model_tests.d/multistrap-examples>
specify a test where the configuration file name is not imposed by the
application. The file name must then be set in the test specification.

=item *

L<backend-shellvar-test-conf.pl|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/backend-shellvar-test-conf.pl>
is a more complex example showing how to test a backend. The test is done creating a dummy model within the test specification.

=back


=head1 SEE ALSO

=for :list
* L<Config::Model>
* L<Test::More>


