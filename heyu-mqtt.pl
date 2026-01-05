#!/usr/bin/perl
use strict;

use AnyEvent::MQTT;
use AnyEvent::Run;

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
};

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

    if ($device eq "raw") { # send 'raw' message, for example "xpreset o3 32" or "fon c2"
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

    # Normalize to lowercase
    $cmd = lc($cmd // '');

    # Heyu monitor may emit variants like AllOff/LightsOn/etc
    my $status;
    if ($cmd eq 'alloff' || $cmd eq 'lightsoff') {
        $status = 0;
    } elsif ($cmd eq 'allon' || $cmd eq 'lightson') {
        $status = 1;
    } else {
        return;
    }

    AE::log info => "House-wide command for $house: $cmd (broadcasting)";

    # Publish an event (useful for HA automations)
    send_house_event($house, $cmd);

    # Publish status updates for known devices in that house
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

        # NEW: detect and broadcast house-wide commands (no unit specified)
        if ($cmd_lc =~ /^(alloff|allon|lightson|lightsoff)$/) {
            process_house_cmd($cmd_lc, $house);
            delete $addr_queue->{$house}; # clear any queued addresses
            return;
        }

        # Existing behavior: apply function to queued units
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

    # Remember device so house-wide commands can update it later
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
