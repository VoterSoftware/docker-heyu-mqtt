#!/usr/bin/perl
use strict;
use warnings;

use AnyEvent::MQTT;
use AnyEvent::Run;

use File::Path qw(make_path);

my $config = {
    mqtt_host      => $ENV{MQTT_HOST} || 'localhost',
    mqtt_port      => $ENV{MQTT_PORT} || '1883',
    mqtt_user      => $ENV{MQTT_USER},
    mqtt_password  => $ENV{MQTT_PASSWORD},
    mqtt_prefix    => $ENV{MQTT_PREFIX} || 'home/x10',
    mqtt_retain_re => qr/$ENV{MQTT_RETAIN_RE}/i || qr//, # retain everything
    heyu_cmd       => $ENV{HEYU_CMD} || 'heyu',

    # If true, translate on/off -> fon/foff for CM17A Firecracker
    use_cm17       => ($ENV{USE_CM17} && $ENV{USE_CM17} =~ /^(1|true|yes|on)$/i) ? 1 : 0,

    # NEW: Set Heyu x10.conf directive from env var (recommended: NO)
    heyu_x10conf        => $ENV{HEYU_X10CONF} || '/etc/heyu/x10.conf',
    heyu_check_ri_line  => $ENV{HEYU_CHECK_RI_LINE},  # e.g. "NO"
};

sub apply_x10conf_directive {
    my (%args) = @_;
    my $path  = $args{path};
    my $key   = $args{key};
    my $value = $args{value};

    return if !defined($value) || $value eq '';

    # Normalize value (optional, but helps avoid "no", "No", etc.)
    $value =~ s/^\s+|\s+$//g;
    $value = uc $value;

    # Ensure directory exists
    if ($path =~ m{^(.*)/[^/]+$}) {
        my $dir = $1;
        eval { make_path($dir) if $dir && !-d $dir; 1 } or do {
            AE::log error => "Failed to create config dir '$dir': $@";
            return;
        };
    }

    my @lines;
    if (-f $path) {
        if (open my $in, '<', $path) {
            @lines = <$in>;
            close $in;
        } else {
            AE::log error => "Failed to read '$path': $!";
            return;
        }
    } else {
        @lines = ();
    }

    my $re = qr/^\s*\Q$key\E\b/i;
    my $found = 0;

    for my $line (@lines) {
        if ($line =~ $re) {
            $line  = "$key  $value\n";
            $found = 1;
        }
    }

    push @lines, "$key  $value\n" unless $found;

    my $tmp = "$path.tmp.$$";
    if (open my $out, '>', $tmp) {
        print $out @lines;
        close $out;

        if (!rename $tmp, $path) {
            AE::log error => "Failed to write '$path' (rename): $!";
            unlink $tmp;
            return;
        }
    } else {
        AE::log error => "Failed to write temp '$tmp': $!";
        return;
    }

    AE::log note => "Applied directive $key $value to $path";
}

# Apply CHECK_RI_LINE before we start heyu monitor / handle commands
if (defined $config->{heyu_check_ri_line} && $config->{heyu_check_ri_line} ne '') {
    apply_x10conf_directive(
        path  => $config->{heyu_x10conf},
        key   => 'CHECK_RI_LINE',
        value => $config->{heyu_check_ri_line},
    );
}

my $mqtt = AnyEvent::MQTT->new(
    host      => $config->{mqtt_host},
    port      => $config->{mqtt_port},
    user_name => $config->{mqtt_user},
    password  => $config->{mqtt_password},
);

# Track devices we've seen/controlled so we can "broadcast" alloff/allon updates
my $known_devices = {};

sub receive_mqtt_set {
    my ($topic, $message) = @_;
    $topic =~ m{\Q$config->{mqtt_prefix}\E/(.*)/set};
    my $device = $1;

    my $msg = lc($message // '');

    if ($device eq "raw") { # e.g. "xpreset o3 32" or "fon c2"
        AE::log info => "X10 sending heyu command $message";

        # IMPORTANT: split multi-word commands into args for system()
        my @args = split /\s+/, $msg;
        system($config->{heyu_cmd}, @args);

    } elsif ($msg =~ m{^(on|off)$}) {
        # Remember device so house-wide commands can update it later
        $known_devices->{$device} = 1;

        # Translate on/off to fon/foff when using CM17A Firecracker
        my $cmd = $msg;
        if ($config->{use_cm17}) {
            $cmd = ($cmd eq 'on') ? 'fon' : 'foff';
        }

        AE::log info => "X10 switching device $device $cmd (from $msg)";
        system($config->{heyu_cmd}, $cmd, $device);
    }
}

sub send_mqtt_status {
    my ($device, $status, $dimlevel) = @_;
    $mqtt->publish(
        topic   => "$config->{mqtt_prefix}/$device",
        message => sprintf('"%s"', $status ? 'on' : 'off')
    );
}

sub send_house_event {
    my ($house, $cmd) = @_;
    $mqtt->publish(
        topic   => "$config->{mqtt_prefix}/house/$house/event",
        message => $cmd
    );
}

sub broadcast_house_status {
    my ($house, $status) = @_;
    for my $dev (keys %$known_devices) {
        next unless $dev =~ /^\Q$house\E\d+$/;  # e.g. C1, C2, ...
        send_mqtt_status($dev, $status);
    }
}

sub process_house_cmd {
    my ($cmd, $house) = @_;

    $cmd = lc($cmd // '');

    my $status;
    if ($cmd eq 'alloff' || $cmd eq 'lightsoff') {
        $status = 0;
    } elsif ($cmd eq 'allon' || $cmd eq 'lightson') {
        $status = 1;
    } else {
        return;
    }

    AE::log info => "House-wide command for $house: $cmd (broadcasting)";

    send_house_event($house, $cmd);
    broadcast_house_status($house, $status);
}

my $addr_queue = {};
sub process_heyu_line {
    my ($handle, $line) = @_;

    if ($line =~ m{Monitor started}) {
        AE::log note => "watching heyu monitor";

    } elsif ($line =~ m{  \S+ addr unit\s+\d+ : hu ([A-Z])(\d+)}) {
        my ($house, $unit) = ($1, $2);
        $addr_queue->{$house} ||= {};
        $addr_queue->{$house}{$unit} = 1;

    } elsif ($line =~ m{  \S+ func\s+(\w+) : hc ([A-Z])}) {
        my ($cmd, $house) = ($1, $2);
        my $cmd_lc = lc $cmd;

        # Detect and broadcast house-wide commands (no unit specified)
        if ($cmd_lc =~ /^(alloff|allon|lightson|lightsoff)$/) {
            process_house_cmd($cmd_lc, $house);
            delete $addr_queue->{$house};
            return;
        }

        # Apply function to queued units
        if ($addr_queue->{$house}) {
            for my $k (keys %{$addr_queue->{$house}}) {
                process_heyu_cmd($cmd_lc, "$house$k", -1);
            }
            delete $addr_queue->{$house};
        }

    } elsif ($line =~ m{  \S+ func\s+(\w+) : hu ([A-Z])(\d+)  level (\d+)}) {
        my ($cmd, $house, $unit, $level) = ($1, $2, $3, $4);
        process_heyu_cmd(lc $cmd, "$house$unit", $level);
    }
}

sub process_heyu_cmd {
    my ($cmd, $device, $level) = @_;

    $known_devices->{$device} = 1;

    AE::log info => "Sending MQTT status for $device: $cmd";
    if ($cmd eq 'on') {
        send_mqtt_status($device, 1);
    } elsif ($cmd eq 'off') {
        send_mqtt_status($device, 0);
    } elsif ($cmd eq 'xpreset') {
        send_mqtt_status($device, 1, $level);
    }
}

$mqtt->subscribe(topic => "$config->{mqtt_prefix}/+/set", callback => \&receive_mqtt_set)->cb(sub {
    AE::log note => "subscribed to MQTT topic $config->{mqtt_prefix}/+/set";
});

my $monitor = AnyEvent::Run->new(
    cmd => [ $config->{heyu_cmd}, 'monitor' ],
    on_read => sub {
        my $handle = shift;
        $handle->push_read( line => \&process_heyu_line );
    },
    on_error => sub {
        my ($handle, $fatal, $msg) = @_;
        AE::log error => "error running heyu monitor: $msg";
    },
);

AnyEvent->condvar->recv;
