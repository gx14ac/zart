#!/usr/bin/expect -f
# Automated OpenBSD 7.9 installation via expect
# Root-only install for kernel development

set timeout 180
set IMG_DIR [file dirname [file normalize [info script]]]
set DISK "$IMG_DIR/openbsd.qcow2"
set ISO "$IMG_DIR/install79.iso"

spawn qemu-system-x86_64 \
    -m 2048 \
    -smp 2 \
    -drive file=$DISK,format=qcow2 \
    -cdrom $ISO \
    -boot d \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::2222-:22 \
    -nographic

# Wait for install menu
expect {
    "boot>" {
        send "set tty com0\n"
        expect "boot>"
        send "\n"
        exp_continue
    }
    -re "\\(I\\)nstall" { send "I\n" }
    timeout { puts "Timeout waiting for install menu"; exit 1 }
}

expect "Terminal type" { send "\n" }
expect "System hostname" { send "openbsd-zart\n" }
expect "Network interface" { send "\n" }
expect "IPv4 address" { send "\n" }
expect "IPv6 address" { send "none\n" }
expect "Network interface" { send "done\n" }

# Password for root (after DNS auto-detect)
expect "Password for root" { send "zart123\n" }
expect "Password for root" { send "zart123\n" }

# sshd
expect "sshd" { send "\n" }

# X Window - no
expect "X Window" { send "no\n" }

# Console to com0
expect "com0" { send "\n" }

# com0 speed
expect "speed" { send "\n" }

# Setup user - no (use root only)
expect "Setup a user" { send "no\n" }

# Allow root ssh
expect "root ssh login" { send "yes\n" }

# Timezone
expect "timezone" { send "Asia/Tokyo\n" }

# Root disk
expect "root disk" { send "\n" }

# Encrypt? no
expect "Encrypt" { send "\n" }

# Whole disk
expect -re "hole disk" { send "\n" }

# Auto layout
expect -re "uto layout" { send "\n" }

# Location of sets
expect "Location of sets" { send "cd0\n" }

# Pathname to sets (default)
expect -re "athname|irectory" { send "\n" }

# CD install: sets auto-selected. Handle verification and completion.
set timeout 600
expect {
    "Set name" {
        send "done\n"
        exp_continue
    }
    -re "without verification|not verified|SHA256" {
        send "yes\n"
        exp_continue
    }
    "Location of sets" {
        send "done\n"
        exp_continue
    }
    "CONGRATULATIONS" { puts "\n==> Installation complete!" }
    timeout { puts "Timeout during install"; exit 1 }
}

# Reboot
expect -re "reboot|halt" { send "reboot\n" }

set timeout 60
expect eof
puts "\n==> OpenBSD installed. Use run-vm.sh to boot."
