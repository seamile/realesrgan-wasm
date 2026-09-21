package main

import (
	"mime"
	"net/http"
)

func main() {
	// Some systems lack a .wasm entry in /etc/mime.types; streaming compile needs it.
	mime.AddExtensionType(".wasm", "application/wasm")

	fs := http.FileServer(http.Dir("./dist"))
	http.Handle("/", cors(fs))
	println("listen on :8000 (serving ./dist)")
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
