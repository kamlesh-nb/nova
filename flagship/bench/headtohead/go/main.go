// Go peer: net/http (the standard library server). GET / returns a constant JSON body.
package main

import (
	"net/http"
	"os"
)

var body = []byte(`{"message":"Hello, World!"}`)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(body)
	})
	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}
	http.ListenAndServe(":"+port, nil)
}
