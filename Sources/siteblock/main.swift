import Foundation
import SiteBlockCore

// Entry point of the siteblock command-line tool: runs the command and exits with its code.
// Exit codes: 0 success, 1 the daemon refused the command, 2 the daemon is not running, 64 usage error.
exit(runCLI(Array(CommandLine.arguments.dropFirst())))
