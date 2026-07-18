package main

import (
	"net/http"
)

func main() {
	fs := http.FileServer(http.Dir("./web"))
	http.Handle("/", cors(fs))
	println("listen on :8000")
	http.ListenAndServe("0.0.0.0:8000", nil)
}

func cors(fs http.Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Required for SharedArrayBuffer / WASM pthread (Route A)
		w.Header().Add("Cross-Origin-Opener-Policy", "same-origin")
		w.Header().Add("Cross-Origin-Embedder-Policy", "require-corp")
		w.Header().Add("Cross-Origin-Resource-Policy", "same-origin")
		fs.ServeHTTP(w, r)
	}
}
