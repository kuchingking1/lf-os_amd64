#!/usr/bin/env perl

# This program generates the kernel syscall parsers and userspace syscall wrappers.
# It's the source of truth for how syscalls are defined on register and instruction level per platform.
# Syscall names, parameters and return values are read from a YAML file which can be used for every platform.
#
# This is the syscall-generator.pl for amd64
# TODO:
# - allocate registers automatically (instead of defining them in the YAML)
# - clean up and remove code duplications

use utf8;
use strict;
use warnings;

use List::Util 'sum';
use YAML 'LoadFile';

my %TYPES = (
    'ptr_t' => {
        length => 64,
        signed => 0,
    },

    uint8_t => {
        length => 8,
        signed => 0,
    },
    uint16_t => {
        length => 16,
        signed => 0,
    },
    uint32_t => {
        length => 32,
        signed => 0,
    },
    uint64_t => {
        length => 64,
        signed => 0,
    },

    int8_t => {
        length => 8,
        signed => 1,
    },
    int16_t => {
        length => 16,
        signed => 1,
    },
    int32_t => {
        length => 32,
        signed => 1,
    },
    int64_t => {
        length => 64,
        signed => 1,
    },

    bool => {
        length => 1,
        signed => 0,
    },

    'void*' => {
        length => 64,
        signed => 0,
    }
);

my %reg_to_inline_asm = (
    rax => 'a',
    rbx => 'b',
    rcx => 'c',
    rdx => 'd',
    rsi => 'S',
    rdi => 'D',
);

sub help {
    print STDERR "Usage: $0 syscalls.yml syscall.gen.c kernel|user\n";
    exit -1;
}

my $infile  = shift @ARGV;
my $outfile = shift @ARGV;
my $mode    = shift @ARGV;

if(!$infile || !$outfile || !$mode || ($mode ne 'kernel' && $mode ne 'user')) {
    help();
}

open(my $outfh, ">", $outfile);
print $outfh <<EOF;
// AUTOMATICALLY GENERATED FILE
// Generated by $0

#include <stdbool.h>
EOF

if($mode eq 'kernel') {
    print $outfh "#include \"bluescreen.h\"\n\n";
}
else {
    print $outfh <<EOF
#include <stdint.h>

EOF
}

sub render_syscall_func {
    my ($group, $syscall) = @_;

    my $name = ($mode eq 'kernel' ? 'sc_handle_'
                                  : 'sc_do_') .
               $group->{name} . '_' . $syscall->{name};

    print $outfh "/** Syscall $syscall->{name} (group $group->{number}, call $syscall->{number})\n *\n"
               . join("\n", map { " *  " . $_ } split("\n", $syscall->{desc}))
               . "\n" . join("\n", map { " *  \\param[in]  $_->{name} $_->{desc}" } $syscall->{parameters}->@*)
               . "\n" . join("\n", map { " *  \\param[out] $_->{name} $_->{desc}" } $syscall->{returns}->@*)
               . "\n */\n";

    print $outfh ($mode eq 'user' ? 'static inline ' : '') . "void $name(";

    print $outfh join(', ', map { "$_->{type} $_->{name}" } (
            $syscall->{parameters}->@*,
            map { { name => $_->{name}, type => $_->{type} . '*' } } $syscall->{returns}->@*,
        )
    );
    print $outfh ")";

    if($mode eq 'user') {
        print $outfh " {\n";

        my %pregs;
        for my $arg ($syscall->{parameters}->@*) {
            push($pregs{$arg->{reg}}->@*, $arg);
        }

        for my $reg (keys %pregs) {
            my $total = sum map { $TYPES{$_->{type}}->{length} } $pregs{$reg}->@*;

            if($total > 64) {
                die("Cannot allocate $total bits on a single register (max 64)\n");
            }

            print $outfh "    uint64_t $reg = ";

            my $bits_before = 0;
            for my $param ($pregs{$reg}->@*) {
                if($bits_before != 0) {
                    print $outfh " | ";
                }

                my $shift = $bits_before;
                my $mask;
                if($TYPES{$param->{type}}->{length} < 64) {
                    $mask  = ' & ' . ((1 << $TYPES{$param->{type}}->{length}) - 1);
                } else {
                    $mask = '';
                }

                if($shift > 0) {
                    print $outfh '(';
                }

                print $outfh "(uint64_t)($param->{name}$mask)";

                if($shift > 0) {
                    print $outfh " << $shift)";
                }

                $bits_before += $TYPES{$param->{type}}->{length};
            }

            print $outfh ";\n";
        }

        die "Group number overflow!\n"   if($group->{number} > 0xFF);
        die "Syscall number overflow!\n" if($syscall->{number} > 0xFFFFFF);

        print $outfh "    uint64_t rdx = (($group->{number} & 0xFF) << 24) | ($syscall->{number} & 0xFFFFFF);\n";

        my %rregs;
        for my $arg ($syscall->{returns}->@*) {
            push($rregs{$arg->{reg}}->@*, $arg);
        }

        for my $reg (keys %rregs) {
            if(!$pregs{$reg}) {
                print $outfh "    uint64_t $reg;\n";
            }
        }

        print $outfh "\n    asm volatile(\"syscall\":";
        print $outfh join(', ', map { '"=' . $reg_to_inline_asm{$_} . "\"($_)" } keys %rregs);
        print $outfh ':';
        print $outfh join(', ', map { '"' . $reg_to_inline_asm{$_} . "\"($_)" } (keys %pregs, 'rdx'));
        print $outfh ':';
        print $outfh '"rbx", "rcx", "r11"';
        print $outfh ");\n\n";

        for my $reg (keys %rregs) {
            my $total = sum map { $TYPES{$_->{type}}->{length} } $rregs{$reg}->@*;

            if($total > 64) {
                die("Cannot allocate $total bits on a single register (max 64)\n");
            }

            my $bits_before = 0;
            for my $return ($rregs{$reg}->@*) {
                my $shift = $bits_before;
                my $mask;
                if($TYPES{$return->{type}}->{length} < 64) {
                    $mask  = ' & ' . ((1 << $TYPES{$return->{type}}->{length}) - 1);
                } else {
                    $mask = '';
                }

                print $outfh "    *$return->{name} = ";

                my $ret;
                if($shift > 0) {
                    $ret = "($return->{reg} >> $shift)";
                }
                else {
                    $ret = $return->{reg};
                }

                print $outfh "($ret$mask);\n";

                $bits_before += $TYPES{$return->{type}}->{length};
            }
        }

        print $outfh "}\n\n";
    } else {
        print $outfh ";\n\n";
    }
}

sub render_syscall_decode {
    my ($group, $syscall) = @_;

    my %pregs;
    for my $arg ($syscall->{parameters}->@*) {
        push($pregs{$arg->{reg}}->@*, $arg);
    }

    print $outfh "                // decoding parameters\n";

    for my $reg (keys %pregs) {
        my $total = sum map { $TYPES{$_->{type}}->{length} } $pregs{$reg}->@*;

        if($total > 64) {
            die("Cannot allocate $total bits on a single register (max 64)\n");
        }

        my $bits_before = 0;
        for my $param ($pregs{$reg}->@*) {
            my $shift = $bits_before;
            my $mask;
            if($TYPES{$param->{type}}->{length} < 64) {
                $mask  = ' & ' . ((1 << $TYPES{$param->{type}}->{length}) - 1);
            } else {
                $mask = '';
            }

            print $outfh "                $param->{type} $param->{name} = ";

            my $ret;
            if($shift > 0) {
                $ret = "(cpu->k$param->{reg} >> $shift)";
            }
            else {
                $ret = "cpu->$param->{reg}";
            }

            print $outfh "($ret$mask);\n";

            $bits_before += $TYPES{$param->{type}}->{length};
        }
    }

    print $outfh "\n                // variables for return values\n";
    for my $ret ($syscall->{returns}->@*) {
        print $outfh "                $ret->{type} $ret->{name};\n";
    }

    print $outfh "\n                // call handler\n";
    my $name = ($mode eq 'kernel' ? 'sc_handle_'
                                  : 'sc_do_') .
               $group->{name} . '_' . $syscall->{name};
    print $outfh "                $name(";
    print $outfh join(', ', (
            (map { $_->{name}       } $syscall->{parameters}->@*),
            (map { '&' . $_->{name} } $syscall->{returns}->@*),
        )
    );
    print $outfh ");";


    print $outfh "\n\n                // encode return values\n";

    my %rregs;
    for my $arg ($syscall->{returns}->@*) {
        push($rregs{$arg->{reg}}->@*, $arg);
    }

    for my $reg (keys %rregs) {
        my $total = sum map { $TYPES{$_->{type}}->{length} } $rregs{$reg}->@*;

        if($total > 64) {
            die("Cannot allocate $total bits on a single register (max 64)\n");
        }

        print $outfh "                cpu->$reg = ";

        my $bits_before = 0;
        for my $return ($rregs{$reg}->@*) {
            if($bits_before != 0) {
                print $outfh " | ";
            }

            my $shift = $bits_before;
            my $mask;
            if($TYPES{$return->{type}}->{length} < 64) {
                $mask  = ' & ' . ((1 << $TYPES{$return->{type}}->{length}) - 1);
            } else {
                $mask = '';
            }

            if($shift > 0) {
                print $outfh '(';
            }

            print $outfh "(uint64_t)($return->{name}$mask)";

            if($shift > 0) {
                print $outfh " << $shift)";
            }

            $bits_before += $TYPES{$return->{type}}->{length};
        }

        print $outfh ";\n";
    }
}

sub process_group {
    my ($group) = @_;

    my $desc_comment = "// Syscall group $group->{name}:\n"
                     . join("\n", map { "//   " . $_ } split("\n", $group->{desc}))
                     . "\n\n";

    print $outfh $desc_comment;

    for my $syscall ($group->{syscalls}->@*) {
        render_syscall_func($group, $syscall);
    }
}

my $indata = LoadFile($infile);
for my $group ($indata->{groups}->@*) {
    process_group($group);
}

if($mode eq 'kernel') {
    print $outfh <<EOF;

void sc_handle(cpu_state* cpu) {
    uint8_t group    = (cpu->rdx >> 24) & 0xFF;
    uint32_t syscall = (cpu->rdx & 0xFFFFFF);

    switch(group) {
EOF

    for my $group ($indata->{groups}->@*) {
        print $outfh "        // group $group->{name}\n";
        print $outfh "        case $group->{number}: switch(syscall) {\n";

        for my $syscall ($group->{syscalls}->@*) {
            print $outfh "            // call $syscall->{name}\n";
            print $outfh "            case $syscall->{number}: {\n";
            render_syscall_decode($group, $syscall);
            print $outfh "            }\n";
            print $outfh "            break;\n";
        }

        print $outfh "            default: panic_message(\"Invalid syscall\");\n";
        print $outfh "        }\n";
        print $outfh "        break;\n";
    }

    print $outfh <<EOF;
        default: panic_message(\"Invalid syscall group\");
    }
}
EOF
}
