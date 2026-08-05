package main
import ("crypto/md5";"fmt";"os";"strconv")
// scalar-per-lane replica of the reference mbrot8: 10x5 = 50 z-iterations with tr/ti carry, membership
// = final (zr^2+zi^2) <= 4.  Bit-identical pixels to the 8-lane 1.go.
func mbrot(cr, ci float64) bool {
    zr, zi, tr, ti := 0.0, 0.0, 0.0, 0.0
    for o := 0; o < 10; o++ {
        for j := 0; j < 5; j++ {
            nzi := 2.0*zr*zi + ci
            nzr := (tr - ti) + cr
            zr, zi = nzr, nzi
            tr, ti = zr*zr, zi*zi
        }
    }
    return tr+ti <= 4.0
}
func main() {
    size := 200
    if len(os.Args) > 1 { if s, err := strconv.Atoi(os.Args[1]); err == nil { size = s } }
    size = (size + 7) / 8 * 8
    w := size / 8
    inv := 2.0 / float64(size)
    pixels := make([]byte, size*w)
    for py := 0; py < size; py++ {
        ci := float64(py)*inv - 1.0
        for bx := 0; bx < w; bx++ {
            var accu byte = 0
            for lane := 0; lane < 8; lane++ {
                cr := float64(bx*8+lane)*inv - 1.5
                if mbrot(cr, ci) { accu |= byte(0x80) >> lane }
            }
            pixels[py*w+bx] = accu
        }
    }
    fmt.Printf("P4\n%d %d\n", size, size)
    fmt.Printf("%x\n", md5.Sum(pixels))
}
