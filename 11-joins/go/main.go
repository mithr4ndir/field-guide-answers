// Drill 11 (joins): Jamf vs. Okta Verify drift report, with dirty keys.
//
// Reads data/jamf_computers.csv and data/okta_devices.json and answers:
// which Macs are missing from Okta Verify (anti-join), which Okta devices
// aren't in Jamf, and how dirty keys and duplicates would have fooled you.
//
// Steps that matter more than the join algorithm:
//
//  1. Normalize the key on both sides: strip whitespace, uppercase.
//  2. Treat blank serials as invalid, not as a key that matches other blanks.
//  3. Check key uniqueness before joining: duplicates multiply join rows.
//  4. Then a hash join (map lookups) does the actual work in O(n + m).
//
// Also times a nested-loop version for comparison and writes drift_report.csv.
package main

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

type jamfComputer struct {
	serial       string
	computerName string
}

// oktaDevice holds the fields this drill uses; encoding/json skips the rest.
// encoding/json can only fill exported (capitalized) fields, and the tags give
// the JSON names. A JSON null leaves a string field at its zero value "", so a
// missing serialNumber needs no special case (Python's `serial or ""`).
type oktaDevice struct {
	ID           string `json:"id"`
	SerialNumber string `json:"serialNumber"`
}

// stringSet is a set of strings. Go has no set type; a map with empty-struct
// values (which take no memory) is the usual stand-in.
type stringSet map[string]struct{}

func (s stringSet) add(k string)      { s[k] = struct{}{} }
func (s stringSet) has(k string) bool { _, ok := s[k]; return ok }

// drillDir finds the 11-joins folder. Go has no __file__ (go run builds the
// program in a temp folder), so look relative to the working directory: the
// repo root, where check.sh runs it, or the drill's own folders.
func drillDir() (string, error) {
	for _, dir := range []string{"11-joins", ".", ".."} {
		if _, err := os.Stat(filepath.Join(dir, "data", "jamf_computers.csv")); err == nil {
			return dir, nil
		}
	}
	return "", errors.New("can't find 11-joins/data/jamf_computers.csv; run from the repo root")
}

// readJamf reads the export by column name, like Python's csv.DictReader.
// csv.Reader handles quoting and drops the \r of the file's \r\n line ends.
// Unlike DictReader, it rejects a row with the wrong number of fields.
func readJamf(path string) ([]jamfComputer, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close() // fine to ignore Close's error on a file you only read
	records, err := csv.NewReader(f).ReadAll()
	if err != nil {
		return nil, err
	}
	if len(records) == 0 {
		return nil, fmt.Errorf("%s: empty file", path)
	}
	col := map[string]int{}
	for i, name := range records[0] {
		col[name] = i
	}
	serialCol, ok1 := col["serial"]
	nameCol, ok2 := col["computer_name"]
	if !ok1 || !ok2 {
		return nil, fmt.Errorf("%s: need serial and computer_name columns", path)
	}
	rows := make([]jamfComputer, 0, len(records)-1)
	for _, rec := range records[1:] {
		rows = append(rows, jamfComputer{serial: rec[serialCol], computerName: rec[nameCol]})
	}
	return rows, nil
}

func readOkta(path string) ([]oktaDevice, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var devices []oktaDevice
	if err := json.Unmarshal(data, &devices); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return devices, nil
}

// norm trims whitespace and uppercases. strings.TrimSpace and strings.ToUpper
// are Unicode-aware like Python's strip() and upper() and identical for ASCII
// serials (one difference: Python also strips the control characters \x1c-\x1f).
func norm(serial string) string {
	return strings.ToUpper(strings.TrimSpace(serial))
}

// countKeys counts each non-blank key, like Counter(k for k in keys if k).
func countKeys(keys []string) map[string]int {
	counts := map[string]int{}
	for _, k := range keys {
		if k != "" {
			counts[k]++
		}
	}
	return counts
}

// moreThanOnce returns how many keys appear more than once.
func moreThanOnce(counts map[string]int) int {
	dups := 0
	for _, n := range counts {
		if n > 1 {
			dups++
		}
	}
	return dups
}

// writeCSV writes rows with "\n" line ends (csv.Writer's default; set UseCRLF
// for "\r\n"). Like Python's csv module it quotes only when needed, except
// that Go also quotes a field that starts with whitespace. These keys are
// trimmed, so the bytes match Python's.
func writeCSV(path string, rows [][]string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if err := csv.NewWriter(f).WriteAll(rows); err != nil { // WriteAll flushes and reports errors
		f.Close()
		return err
	}
	return f.Close() // check Close on files you write: it can report a failed write
}

func main() {
	dir, err := drillDir()
	if err != nil {
		log.Fatal(err)
	}
	jamf, err := readJamf(filepath.Join(dir, "data", "jamf_computers.csv"))
	if err != nil {
		log.Fatal(err)
	}
	okta, err := readOkta(filepath.Join(dir, "data", "okta_devices.json"))
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("Drill 11: Jamf vs. Okta Verify drift report.")
	fmt.Printf("Rows: Jamf %s, Okta %s\n", commas(len(jamf)), commas(len(okta)))

	jamfKeys := make([]string, len(jamf))
	for i, r := range jamf {
		jamfKeys[i] = norm(r.serial)
	}
	oktaKeys := make([]string, len(okta))
	for i, r := range okta {
		oktaKeys[i] = norm(r.SerialNumber)
	}
	fmt.Printf("Blank serials skipped: Jamf %d, Okta %d\n", countBlank(jamfKeys), countBlank(oktaKeys))

	jamfCount, oktaCount := countKeys(jamfKeys), countKeys(oktaKeys)
	fmt.Printf("Serials listed more than once (after normalizing): Jamf %d, Okta %d\n",
		moreThanOnce(jamfCount), moreThanOnce(oktaCount))

	// Hash join on distinct normalized keys: build the index once, probe it once.
	// A missing map key reads as 0, so a count doubles as a membership test.
	jamfSet, both, jamfOnly, oktaOnly := stringSet{}, stringSet{}, stringSet{}, stringSet{}
	for k := range jamfCount {
		jamfSet.add(k)
		if oktaCount[k] > 0 {
			both.add(k)
		} else {
			jamfOnly.add(k)
		}
	}
	for k := range oktaCount {
		if jamfCount[k] == 0 {
			oktaOnly.add(k)
		}
	}
	fmt.Printf("Devices in both: %s\n", commas(len(both)))
	fmt.Printf("In Jamf, missing from Okta Verify: %s\n", commas(len(jamfOnly)))
	fmt.Printf("In Okta, not in Jamf: %s\n", commas(len(oktaOnly)))

	// What a join on raw, unnormalized serials would have claimed.
	oktaRaw := stringSet{}
	for _, r := range okta {
		if r.SerialNumber != "" {
			oktaRaw.add(r.SerialNumber)
		}
	}
	rawMissing := stringSet{}
	for _, r := range jamf {
		if r.serial != "" && !oktaRaw.has(r.serial) {
			rawMissing.add(r.serial)
		}
	}
	fmt.Printf("Joining on raw serials would report %s missing: %d false alarms from case and whitespace\n",
		commas(len(rawMissing)), len(rawMissing)-len(jamfOnly))

	joinRows := 0
	for k := range both {
		joinRows += jamfCount[k] * oktaCount[k]
	}
	fmt.Printf("A plain inner join returns %s rows for %s devices (+%d from duplicate keys)\n",
		commas(joinRows), commas(len(both)), joinRows-len(both))

	// The same anti-join as a nested loop, for timing only.
	var oktaList []string
	for _, k := range oktaKeys {
		if k != "" {
			oktaList = append(oktaList, k)
		}
	}
	start := time.Now()
	nestedMissing := stringSet{}
	for k := range jamfSet {
		matches := 0
		for _, o := range oktaList { // scans the whole list, like the Python list comprehension
			if o == k {
				matches++
			}
		}
		if matches == 0 {
			nestedMissing.add(k)
		}
	}
	tNested := time.Since(start)
	start = time.Now()
	index := make(stringSet, len(oktaList))
	for _, o := range oktaList {
		index.add(o)
	}
	hashMissing := stringSet{}
	for k := range jamfSet {
		if !index.has(k) {
			hashMissing.add(k)
		}
	}
	tHash := time.Since(start)
	if !maps.Equal(nestedMissing, hashMissing) || !maps.Equal(hashMissing, jamfOnly) {
		panic("the nested loop, the hash join and the set difference must agree") // Go has no assert
	}

	// The first row seen for each key, in file order (Python's setdefault).
	firstJamf := map[string]string{}
	for i, r := range jamf {
		if _, seen := firstJamf[jamfKeys[i]]; !seen {
			firstJamf[jamfKeys[i]] = r.computerName
		}
	}
	firstOkta := map[string]string{}
	for i, r := range okta {
		if _, seen := firstOkta[oktaKeys[i]]; !seen {
			firstOkta[oktaKeys[i]] = r.ID
		}
	}

	all := make([]string, 0, len(jamfSet)+len(oktaOnly))
	for k := range jamfSet {
		all = append(all, k)
	}
	for k := range oktaOnly {
		all = append(all, k)
	}
	// Map order is random, so sort. Byte order on UTF-8 equals Python's code point order.
	slices.Sort(all)
	rows := [][]string{{"serial", "status", "jamf_computer_name", "okta_device_id"}}
	for _, k := range all {
		status := "okta_only"
		if both.has(k) {
			status = "both"
		} else if jamfOnly.has(k) {
			status = "jamf_only"
		}
		rows = append(rows, []string{k, status, firstJamf[k], firstOkta[k]}) // a missing key gives ""
	}
	if err := writeCSV(filepath.Join(dir, "drift_report.csv"), rows); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Wrote drift_report.csv (%s rows)\n", commas(len(all)))
	fmt.Printf("~ anti-join timing: nested loop %.3f s, hash %.2f ms (%sx faster)\n",
		tNested.Seconds(), tHash.Seconds()*1000, commasF(tNested.Seconds()/tHash.Seconds()))
}

// countBlank counts empty keys, like Python's keys.count("").
func countBlank(keys []string) int {
	n := 0
	for _, k := range keys {
		if k == "" {
			n++
		}
	}
	return n
}

// commas formats n with thousands separators, like Python's f"{n:,}".
func commas(n int) string { return group(strconv.Itoa(n)) }

// commasF rounds x to a whole number with separators, like f"{x:,.0f}".
func commasF(x float64) string { return group(strconv.FormatFloat(x, 'f', 0, 64)) }

// group inserts a comma every three digits from the right, after any sign.
func group(s string) string {
	head := len(s) - len(strings.TrimLeft(s, "+-"))
	for i := len(s) - 3; i > head; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}
