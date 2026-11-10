module parcheturn

go 1.24.7

replace golang.org/x/crypto => github.com/golang/crypto v0.31.0

replace golang.org/x/net => github.com/golang/net v0.33.0

replace golang.org/x/sys => github.com/golang/sys v0.28.0

replace golang.org/x/text => github.com/golang/text v0.21.0

require (
	github.com/pion/logging v0.2.2
	github.com/pion/turn/v4 v4.0.0
)

require (
	github.com/pion/dtls/v3 v3.0.1 // indirect
	github.com/pion/randutil v0.1.0 // indirect
	github.com/pion/stun/v3 v3.0.0 // indirect
	github.com/pion/transport/v3 v3.0.7 // indirect
	github.com/wlynxg/anet v0.0.3 // indirect
	golang.org/x/crypto v0.25.0 // indirect
	golang.org/x/sys v0.28.0 // indirect
)
