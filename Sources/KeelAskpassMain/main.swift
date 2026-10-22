import Darwin
import Foundation
import KeelAskpass

// Run by /usr/bin/ssh as SSH_ASKPASS for tunnels of hosts with a saved password. A prompt it cannot answer from the
// broker exits non-zero (no terminal), which ssh treats as declined: it never prints a guess, since ssh would send it.
exit(AskpassHelper(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment).run())
