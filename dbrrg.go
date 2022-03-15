package main

import (
	"net/http"
	"time"
)

type timeHandler struct {
	format string
}

func (th timeHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	tm := time.Now().Format(th.format)
	w.Write([]byte("The time is: " + tm))
}

func main() {
	muxer := http.NewServeMux()
	fileServer := http.FileServer(http.Dir("image-export"))
	th := timeHandler{format: time.RFC1123}
	muxer.Handle("/", fileServer)
	muxer.Handle("/ipxe.cfg", th)
	http.ListenAndServe(":8080", muxer)
}
