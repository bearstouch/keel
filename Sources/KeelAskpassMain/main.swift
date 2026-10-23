import Darwin
import Foundation
import KeelAskpass

// Run by /usr/bin/ssh as SSH_ASKPASS for every tunnel. The broker answers ssh's first password prompt from the saved
// password and relays every other prompt to the person (KEEL-010). A prompt nobody answers exits non-zero (no
// terminal), which ssh treats as declined: the helper never prints a guess, since ssh would send it.
exit(AskpassHelper(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment).run())
