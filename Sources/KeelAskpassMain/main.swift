import Foundation
import KeelAskpass

// Until the askpass broker exists (KEEL-010) the helper answers nothing: exiting non-zero makes ssh treat the prompt
// as declined, which is the safe outcome. It never prints a guess on stdout, because ssh would send it as a password.
_ = KeelAskpassModule.name
exit(1)
