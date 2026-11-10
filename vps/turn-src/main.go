package main

import (
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"github.com/pion/turn/v4"
)

func main() {
	pub := os.Getenv("TURN_PUBLIC_IP")
	user := os.Getenv("TURN_USER")
	pass := os.Getenv("TURN_PASS")
	port := os.Getenv("TURN_PORT")
	if port == "" {
		port = "3478"
	}
	if pub == "" || user == "" || pass == "" {
		log.Fatal("faltan TURN_PUBLIC_IP, TURN_USER o TURN_PASS")
	}
	udp, err := net.ListenPacket("udp4", "0.0.0.0:"+port)
	if err != nil {
		log.Fatalf("udp: %v", err)
	}
	tcp, err := net.Listen("tcp4", "0.0.0.0:"+port)
	if err != nil {
		log.Fatalf("tcp: %v", err)
	}
	key := turn.GenerateAuthKey(user, "parche", pass)
	gen := &turn.RelayAddressGeneratorPortRange{
		RelayAddress: net.ParseIP(pub),
		Address:      "0.0.0.0",
		MinPort:      50000,
		MaxPort:      50500,
	}
	s, err := turn.NewServer(turn.ServerConfig{
		Realm: "parche",
		AuthHandler: func(username, realm string, srcAddr net.Addr) ([]byte, bool) {
			if username == user {
				return key, true
			}
			return nil, false
		},
		PacketConnConfigs: []turn.PacketConnConfig{{PacketConn: udp, RelayAddressGenerator: gen}},
		ListenerConfigs:   []turn.ListenerConfig{{Listener: tcp, RelayAddressGenerator: gen}},
	})
	if err != nil {
		log.Fatalf("server: %v", err)
	}
	log.Println("TURN listo en puerto " + port + " (relay " + strconv.Itoa(50000) + "-" + strconv.Itoa(50500) + ")")
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	_ = s.Close()
}
