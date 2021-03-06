#!/usr/bin/perl -w

use strict;
use POSIX qw(:sys_wait_h mkfifo);
use Fcntl qw(:flock);
use File::Spec;
use Lexical::Persistence;
use IO::Socket::UNIX qw( SOCK_STREAM SOMAXCONN );
use Data::Dumper;
use Try::Tiny;
use Data::Dumper;
use cells;





my $root_lock_fh = cells::acquire_lock_for_path(cells::root_pid_path_for_pid($$));

my $lock_fh = cells::acquire_lock_for_path(cells::lockfile_path_for_pid($$));
my $ancestry_lock_fh;
my $lp = Lexical::Persistence->new();



my $listener = cells::create_listener_socket_for_pid($$);

while(1){
    my $socket = $listener->accept()
       or die("Can't accept connection: $!\n");
    my $request_line = <$socket>;
    chomp $request_line;
    print qq{Client Sez "$request_line"\n};



    my $resp_hash={};

    my $parent_pid = $$;
    
    #Kill all previous forks before creating a new one
    cells::kill_descendants_of_pid($parent_pid);
    
    my $fork_pid = fork();

    if(defined($fork_pid)){

        if($fork_pid){
            #Parent
            close($socket) or die "Can't close socket: $!";

        }else{
            #Child
            $lock_fh = cells::acquire_lock_for_path(cells::lockfile_path_for_pid($$));
            $listener->close or die "can't close the parent's listening socket: $!";
            $listener = cells::create_listener_socket_for_pid($$);


            my $current_task_file = cells::current_task_path_for_pid($$);
            cells::set_contents_of_file($current_task_file, $request_line);

            my $ancestry_lockfile_path = cells::ancestry_path_for_parent_child_pids($parent_pid, $$);
            $ancestry_lock_fh = cells::acquire_lock_for_path($ancestry_lockfile_path);

            my $working_pid_lock_fh = cells::acquire_lock_for_path(cells::working_pids_path_for_pid($$));

            $resp_hash->{new_pid} = $$;

            my $request = cells::decode_hash($request_line);
            warn Dumper $request;

            my $coderef = $lp->compile($request->{code});


            if($coderef){
                try{
                    my @code_returned_data = $lp->call( $coderef );
                    try {
                        local $Data::Dumper::Terse=1;
                        local $Data::Dumper::Quotekeys=0;
                        local $Data::Dumper::Useqq=1;
                        local $Data::Dumper::Sortkeys=1;
                        local $Data::Dumper::Indent=1;
                        $resp_hash->{return_data} = join ",\n", (map {my $x=Dumper($_);chop $x; $x} @code_returned_data);
                        $resp_hash->{response_type} = 'good';
                    } catch {
                        $resp_hash->{return_data} = $_;
                        $resp_hash->{response_type} = 'dumping_error';
                    }
                } catch {
                    $resp_hash->{return_data} = $_;
                    $resp_hash->{response_type} = 'exec_error';
                };
            }else{
                $resp_hash->{return_data} = $@;
                $resp_hash->{response_type} = 'comp_error';
            }

            my $response = cells::encode_hash($resp_hash);

            print $socket "$response\n";
            close($socket) or die "Can't close socket: $!";
            cells::unlock_lock_fh($working_pid_lock_fh);
            
            cells::set_contents_of_file(cells::last_finished_pid_path(),$$);
            
        }


    }else{
        $resp_hash->{return_data} = "Fork failed";
        $resp_hash->{response_type} = 'misc_error';
        my $response = cells::encode_hash($resp_hash);

        print $socket "$response\n";
        close($socket) or die "Can't close socket: $!";
    }





}
