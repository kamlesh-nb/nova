package main
import ("fmt";"os";"strconv")
func sieve(flags []bool, m int) int {
    for i := 0; i < m; i++ { flags[i] = true }
    count := 0
    for i := 2; i < m; i++ { if flags[i] { count++; for j := i+i; j < m; j += i { flags[j] = false } } }
    return count
}
func main() {
    n := 4; if len(os.Args) > 1 { n, _ = strconv.Atoi(os.Args[1]) }
    reps := 400; max := 10000 << n; flags := make([]bool, max)
    a,b,c := 0,0,0
    for r := 0; r < reps; r++ { a=sieve(flags,10000<<n); b=sieve(flags,10000<<(n-1)); c=sieve(flags,10000<<(n-2)) }
    fmt.Printf("Primes up to %8d %8d\n", 10000<<n, a)
    fmt.Printf("Primes up to %8d %8d\n", 10000<<(n-1), b)
    fmt.Printf("Primes up to %8d %8d\n", 10000<<(n-2), c)
}
