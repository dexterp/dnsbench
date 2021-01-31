package options

import (
	"github.com/docopt/docopt-go"
)

// GetUsage parses docstring for usage information
func GetUsage(argv []string, version string) *Options {
	usage := `dnsbench

Usage:
  dnsbench [-o=<csv>] [-t=<threads>] [-i=<interval>] [-n=<hostname>] [-m=<info>] <duration>

Options:
  -h --help      Show this screen.
  --version      Show version.
  -m=<info>      Add information to records.
  -t=<threads>   Number of lookup threads [default: 1].
  -i=<interval>  Interval in seconds [default: 5].
  -o=<csv>       CSV output file [default: dnsbench.csv].
  -n=<hostname>  Hostname to lookup [default: google.com].
  <duration>     Duration in seconds to run test.
`

	opts, err := docopt.ParseArgs(usage, argv, version)
	if err != nil {
		panic(err)
	}
	config := &Options{}
	err = opts.Bind(config)
	if err != nil {
		panic(err)
	}
	return config
}

// Options docopt options
type Options struct {
	CSV      string `docopt:"-o"`
	Duration int64  `docopt:"<duration>"`
	Hostname string `docopt:"-n"`
	Info     string `docopt:"-m"`
	Interval int    `docopt:"-i"`
	Threads  int    `docopt:"-t"`
}
