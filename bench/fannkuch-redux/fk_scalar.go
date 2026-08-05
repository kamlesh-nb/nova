package main
import ("fmt";"os";"strconv")
func fannkuch(n int) (int, int) {
    perm := make([]int, n); perm1 := make([]int, n); count := make([]int, n)
    for i := range perm1 { perm1[i] = i }
    r := n; maxFlips, checksum, permIndex := 0, 0, 0
    for {
        for r != 1 { count[r-1] = r; r-- }
        copy(perm, perm1)
        flips := 0; k := perm[0]
        for k != 0 { for lo, hi := 0, k; lo < hi; lo, hi = lo+1, hi-1 { perm[lo], perm[hi] = perm[hi], perm[lo] }; flips++; k = perm[0] }
        if flips > maxFlips { maxFlips = flips }
        if permIndex%2 == 0 { checksum += flips } else { checksum -= flips }
        done := false
        for {
            if r == n { done = true; break }
            p0 := perm1[0]; for m := 0; m < r; m++ { perm1[m] = perm1[m+1] }; perm1[r] = p0
            count[r]--; if count[r] > 0 { break }; r++
        }
        if done { break }
        permIndex++
    }
    return checksum, maxFlips
}
func main() {
    n := 7; if len(os.Args) > 1 { n, _ = strconv.Atoi(os.Args[1]) }
    c, m := fannkuch(n); fmt.Printf("%d\nPfannkuchen(%d) = %d\n", c, n, m)
}
