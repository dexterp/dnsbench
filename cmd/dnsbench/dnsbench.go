package main

import (
	"fmt"
	"net"
	"os"
	"sync"
	"time"

	"encoding/csv"

	"github.com/dexterp/dnsbench/internal"
	"github.com/dexterp/dnsbench/internal/options"
	"github.com/google/uuid"
)

func main() {
	opts := options.GetUsage(os.Args[1:], internal.Version)

	// DI Container managing the creation of objects
	shutdown := false
	start := time.Now()
	end := start.Add(time.Duration(opts.Duration) * time.Second)
	s := &settings{
		counts:   make(chan int, 128),
		csv:      opts.CSV,
		duration: time.Duration(opts.Duration),
		hostname: opts.Hostname,
		info:     opts.Info,
		interval: opts.Interval,
		muWrite:  &sync.Mutex{},
		shutdown: &shutdown,
		start:    start,
		threads:  uint(opts.Threads),
		end:      end,
		uuid:     uuid.New().String(),
		wg:       &sync.WaitGroup{},
	}

	// NS Lookup
	look := s.injectLookup()
	report := s.injectReporter()

	// Start report
	report.start()
	// Write loop
	report.writerLoop()
	// Start lookups
	look.start()
	// Finish
	report.finish()
}

//
// Dependency Injection container
//

// settings implements a DI container
type settings struct {
	counts   chan int
	csv      string
	duration time.Duration
	end      time.Time
	info     string
	interval int
	hostname string
	muWrite  *sync.Mutex
	shutdown *bool
	start    time.Time
	threads  uint
	uuid     string
	wg       *sync.WaitGroup
}

// injectLookup inject *lookup struct
func (s *settings) injectLookup() *lookup {
	return &lookup{
		counts:   s.counts,
		hostname: s.hostname,
		shutdown: s.shutdown,
		wg:       s.wg,
		threads:  s.threads,
	}
}

// injectWriter inject *csv.Writer
func (s *settings) injectWriter() *csv.Writer {
	// w, err := os.OpenFile(s.csv, os.O_TRUNC|os.O_CREATE|os.O_WRONLY, 0644)
	// if err != nil {
	//	panic(err)
	//}
	return csv.NewWriter(os.Stdout)
}

// injectReporter inject *csvWriter struct
func (s *settings) injectReporter() *reporter {
	return &reporter{
		counts:   s.counts,
		csv:      s.csv,
		duration: s.duration,
		end:      s.end,
		info:     s.info,
		interval: s.interval,
		mu:       s.muWrite,
		shutdown: s.shutdown,
		uuid:     s.uuid,
		w:        s.injectWriter(),
		wg:       s.wg,
	}
}

//
// Reporter
//

// reporter writes to csv files
type reporter struct {
	counts   <-chan int
	csv      string // csv file
	duration time.Duration
	end      time.Time
	info     string
	interval int
	mu       *sync.Mutex
	shutdown *bool
	uuid     string
	w        *csv.Writer
	wg       *sync.WaitGroup
}

func (c *reporter) start() {
	// header
	header := []string{"_time", "uuid", "type", "count", "avg_time_ms", "interval", "info"}
	err := c.w.Write(header)
	if err != nil {
		panic(err)
	}

	start := []string{fmt.Sprintf("%d", time.Now().Unix()), c.uuid, "start", "", "", "", c.info}
	err = c.w.Write(start)
	if err != nil {
		panic(err)
	}
}

func (c *reporter) writerLoop() {
	cur := 0
	ticker := time.NewTicker(time.Duration(c.interval) * time.Second)
	for i := 0; i < 1; i++ {
		go func() {
			for {
				if *c.shutdown {
					break
				}
				select {
				case <-ticker.C:
					resp := (float32(c.interval) / float32(cur)) * 1000
					event := []string{fmt.Sprintf("%d", time.Now().Unix()), c.uuid, "metric", fmt.Sprintf("%d", cur), fmt.Sprintf("%.3f", resp), fmt.Sprintf("%d", c.interval), ""}
					err := c.w.Write(event)
					if err != nil {
						panic(err)
					}
					c.w.Flush()
					cur = 0
				case i := <-c.counts:
					cur += i
				}
			}
		}()
	}
}

func (c *reporter) finish() {
	for time.Now().Before(c.end) {
		time.Sleep(time.Second)
	}
	*c.shutdown = true
	c.wg.Wait()
	event := []string{fmt.Sprintf("%d", time.Now().Unix()), c.uuid, "end", "", "", ""}
	err := c.w.Write(event)
	if err != nil {
		panic(err)
	}
	c.w.Flush()
}

//
// Host Lookup
//

// lookup performs resolver lookups
type lookup struct {
	counts   chan<- int
	hostname string
	threads  uint
	shutdown *bool
	wg       *sync.WaitGroup
}

// start resolves hostname
func (l *lookup) start() {
	for i := uint(0); i < l.threads; i++ {
		l.wg.Add(1)
		go func() {
			defer l.wg.Done()
			for {
				if *l.shutdown {
					break
				}
				_, err := net.LookupIP(l.hostname)
				if err != nil {
					panic(err)
				}
				l.counts <- 1
			}
		}()
	}
}
