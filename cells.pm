package cells;
use strict;
use POSIX qw(:sys_wait_h mkfifo);
use Fcntl qw(:flock);
use File::Spec;
use File::Basename;
use JSON::PP;
use URI::Escape;
use IO::Socket::UNIX qw( SOCK_STREAM SOMAXCONN );
use Carp;


#THIS FUNCTION MOST LIKELY HAS RACE CONDITIONS
sub delete_temp_files{
    if(-e pidlocks_dir()){
        my @lockfiles = get_directory_contents(pidlocks_dir());
        for my $file(@lockfiles){
            if(not file_is_locked($file)){
                unlink $file or confess "can't delete $file: $!";
            }
        }
    }
    my @active_pids = get_active_pids();

    delete_unmentioned_pidfiles_in_dir(sockets_dir(), [@active_pids] );
    delete_unmentioned_pidfiles_in_dir(working_pids_dir(), [@active_pids] );
    delete_unmentioned_pidfiles_in_dir(current_tasks_dir(), [@active_pids] );
    delete_unmentioned_pidfiles_in_dir(root_pids_dir(), [@active_pids] );


    if(-e ancestry_dir()){
        my @ancestry_dirs = get_directory_contents(ancestry_dir());
        for my $ancestry_dir(@ancestry_dirs){
            delete_unmentioned_pidfiles_in_dir($ancestry_dir, [@active_pids]);
            my @leftovers = get_directory_contents($ancestry_dir);
            unless(@leftovers){
                rmdir $ancestry_dir or confess "can't delete $ancestry_dir: $!";
            }
        }
    }
}

sub delete_unmentioned_pidfiles_in_dir{
    my $dir = shift;
    my @mentioned_pids = @{ shift() };
    my %mentioned_pid_h = map {$_ => 1} @mentioned_pids;
    if(-e $dir){
        my @pidfiles = get_directory_contents($dir);
        for my $pid_file(@pidfiles){
            my $pid = basename $pid_file;
            if($mentioned_pid_h{$pid}){
                #mentioned, no delete
            }else{
                unlink $pid_file or confess "can't delete $pid_file: $!";
            }
        }
    }
}

sub get_active_pids{
    my @active_pids;
    if(-e pidlocks_dir()){
        my @lockfiles = get_directory_contents(pidlocks_dir());
        for my $file(@lockfiles){
            if( file_is_locked($file)){
                push @active_pids, basename $file;
            }
        }
    }
    return @active_pids;
}

sub root_dir{
    return 'perl_cells_data';
}

sub get_directory_contents{
    my $dir = shift;

    opendir(my $dh, $dir) or confess "Can't open directory $dir: $!\n";
    my @files = grep !/^\.\.?$/, readdir($dh);
    @files = map {File::Spec->catdir($dir, $_)} @files;
    return @files;
}

sub pidlocks_dir{
    return File::Spec->catdir(root_dir(), 'pidlocks');
}

sub sockets_dir{
    return File::Spec->catdir(root_dir(), 'sockets');
}

sub ancestry_dir{
    return File::Spec->catdir(root_dir(), 'ancestry');
}


sub working_pids_dir{
    return File::Spec->catdir(root_dir(), 'working_pids');
}

sub current_tasks_dir{
    return File::Spec->catdir(root_dir(), 'current_tasks');
}

sub root_pids_dir{
    return File::Spec->catdir(root_dir(), 'root_pids');
}

sub socket_path_for_pid{
    my $pid = shift;
    return File::Spec->catdir(sockets_dir(), $pid);
}

sub lockfile_path_for_pid{
    my $pid = shift;
    return File::Spec->catdir(pidlocks_dir(), $pid);
}

sub working_pids_path_for_pid{
    my $pid = shift;
    return File::Spec->catdir(working_pids_dir(), $pid);
}

sub current_task_path_for_pid{
    my $pid = shift;
    return File::Spec->catdir(current_tasks_dir(), $pid);
}

sub root_pid_path_for_pid{
    my $pid = shift;
    return File::Spec->catdir(root_pids_dir(), $pid);
}

sub last_finished_pid_path{
    return File::Spec->catdir(root_dir(), 'last_finished_pid');
}

sub get_pids_from_lockfiles{
    my @pids = get_directory_contents(pidlocks_dir());

    @pids = map {basename $_} @pids;

    return @pids;
}

sub ancestry_path_for_parent_child_pids{
    my $parent = shift;
    my $child = shift;

    return File::Spec->catdir(ancestry_dir(), $parent, $child);
}

sub make_fifo{
    my $path = shift;
    mkfifo($path, 0700) or confess "mkfifo $path failed: $!";
}

sub open_for_reading{
    my $path = shift;
    open(my $fh, "<", $path) or confess "cannot open $path: $!";
    return $fh;
}

sub open_for_writing{
    my $path = shift;
    open(my $fh, ">", $path) or confess "cannot open $path: $!";
    return $fh;
}

sub ensure_parent_dir_exist{
    my $path = shift;

    my $parent = chop_path($path);
    prep_and_check_dir($parent);
}

sub chop_path{
    my $path = shift;
    my @dirs = File::Spec->splitdir($path);
    pop @dirs;
    return File::Spec->catdir(@dirs);
}

sub prep_and_check_dir{
    my $dir = shift;

    if($dir eq ''){
        #root always exists
        return;
    }

    if(not -e $dir){
        my $parent = chop_path($dir);
        prep_and_check_dir($parent);
        mkdir $dir or confess "can't create dir: $!";
    }
    if(not (-r $dir and -w $dir)){
        confess "something is wrong with $dir";
    }
}

sub acquire_lockfile{ #NONBLOCKING THIS MAY NOT BE RIGHT
    #returns lock fh
    my $lockfile = shift;
    my $lock_fh;
    unless(open $lock_fh, ">", $lockfile){
        confess "cant open lockfile: $!";
    }
    if(flock($lock_fh, LOCK_EX|LOCK_NB)){
        #was able to lock
        return $lock_fh
    }else{
        confess "cant lock lockfile";
    }
}

sub unlock_lock_fh{
    my $lock_fh = shift;
    flock($lock_fh, LOCK_UN) or confess "can't unlock: $!";
    close($lock_fh) or confess "can't close lock fh: $!";
}

sub file_is_locked{
    my $lockfile = shift;
    my $lock_fh;
    unless(open $lock_fh, "<", $lockfile){
        #cant open
        #not locked
        return 0;
    }
    if(flock($lock_fh, LOCK_EX|LOCK_NB)){
        #was able to lock -- which means no one else was locking it
        unlock_lock_fh($lock_fh);
        return 0;
    }else{
        #already locked
        close($lock_fh) or confess "can't close lock fh: $!";
        return 1;
    }
}

sub acquire_lock_for_path{
    my $lockfile_path = shift;
    cells::ensure_parent_dir_exist($lockfile_path);
    my $lock_fh = cells::acquire_lockfile($lockfile_path);
    return $lock_fh;
}

sub get_contents_of_file{
    my $path = shift;

    if(not -e $path){
        confess "$path does not exist";
    }

    if(open(my $f, '<', $path)){
        my $string = do { local($/); <$f> };
        close($f);
        return $string;
    }else{
        confess "can't open $path: $!";
    }
}

sub set_contents_of_file{
    my $path = shift;
    my $contents = shift;
    cells::ensure_parent_dir_exist($path);
    my $fh = cells::open_for_writing($path);
    print $fh $contents;
    close($fh) or confess "Cant close $path: $!";
}

sub encode_hash{
    my $hash = shift;
    return uri_escape(encode_json($hash));
}

sub decode_hash{
    my $msg = shift;
    return decode_json(uri_unescape($msg));
}

sub send_hash_to_pid_and_wait_for_response{
    my $hash = shift;
    my $pid  = shift;

    my $message = encode_hash($hash);

    my $socket_path = cells::socket_path_for_pid($pid);
    my $socket = IO::Socket::UNIX->new(
       Type => SOCK_STREAM,
       Peer => $socket_path,
    ) or confess("Can't connect to server: $@\n");

    print $socket "$message\n";
    my $resp_line = <$socket> ;
    close $socket;
    chomp $resp_line;
    my $resp_hash = decode_hash($resp_line);
    return $resp_hash;
}

sub create_listener_socket_for_pid{
    my $pid = shift;
    my $socket_path = cells::socket_path_for_pid($pid);
    cells::ensure_parent_dir_exist($socket_path);

    unlink($socket_path);

    my $listener = IO::Socket::UNIX->new(
       Type   => SOCK_STREAM,
       Local  => $socket_path,
       Listen => SOMAXCONN,
    ) or confess("Can't create server socket: $!\n");
    return $listener;
}

sub get_parent_child_relationships{
    my @relations;
    
    if(-e ancestry_dir()){
        my @ancestry_dirs = get_directory_contents(ancestry_dir());
        for my $parent_dir(@ancestry_dirs){
            my $parent_pid = basename $parent_dir;
            my @child_files = get_directory_contents($parent_dir);
            for my $child_file(@child_files){
                if(file_is_locked($child_file)){
                    my $child_pid = basename $child_file;
                    my $relation = {
                        parent => $parent_pid,
                        child  => $child_pid
                    };
                    push @relations, $relation;
                }
            }
        }
    }
    
    return @relations;
}

sub get_default_pid_to_send_commands_to{
    #Returns undef in case nothing found
    my @alive_pids = get_active_pids();
    if(-e last_finished_pid_path()){
        my $pid = get_contents_of_file(last_finished_pid_path());
        if($pid =~ /\D/){
            carp "Last finished pid is not a valid pid: '$pid'";
        }else{
            if(grep {$_ == $pid} @alive_pids){
                return $pid;
            }else{
                carp "Last finished pid is no longer among the living";
            }
        }
    }
        
    if(@alive_pids){
        carp "using an essentially random living pid";
        return $alive_pids[0];
    }else{
        return;
    }
    
}

#This function is hilariously inefficient, it should be made non recursive
sub kill_descendants_of_pid{
    my $pid = shift;
    my @relations = get_parent_child_relationships();
    
    my @spawned_child_relations = grep {$_->{parent} == $pid} @relations;

    my @child_pids = map {$_->{child}} @spawned_child_relations;
    for my $child_pid(@child_pids){
        warn "killing $child_pid 's children\n";
        kill_descendants_of_pid($child_pid);
        warn "killing $child_pid\n";
        my $n_killed = kill 'KILL', $child_pid;
        if(not $n_killed){
            carp "Failed to kill PID $child_pid";
        }
    }

}

1;