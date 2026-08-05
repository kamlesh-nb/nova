fn sieve(flags: &mut [bool], m: usize) -> i32 {
    for x in flags[..m].iter_mut() { *x = true; }
    let mut count = 0; let mut i = 2;
    while i < m { if flags[i] { count += 1; let mut j = i+i; while j < m { flags[j]=false; j+=i; } } i += 1; }
    count
}
fn main() {
    let n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(4);
    let reps = 400; let max = 10000usize << n; let mut flags = vec![false; max];
    let (mut a,mut b,mut c) = (0,0,0);
    for _ in 0..reps { a=sieve(&mut flags, 10000<<n); b=sieve(&mut flags, 10000<<(n-1)); c=sieve(&mut flags, 10000<<(n-2)); }
    println!("Primes up to {:8} {:8}", 10000<<n, a);
    println!("Primes up to {:8} {:8}", 10000<<(n-1), b);
    println!("Primes up to {:8} {:8}", 10000<<(n-2), c);
}
