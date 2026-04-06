package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

type Disk struct {
	Name       string `json:"name"`
	Size       string `json:"size"`
	Type       string `json:"type"`
	MountPoint string `json:"mountpoint"`
	Serial     string `json:"serial"`
	Model      string `json:"model"`
	Rotational bool   `json:"rotational"`
	Transport  string `json:"transport"`
	IsVirtual  bool   `json:"is_virtual"`
	OS         string `json:"os,omitempty"`
}

type InstallRequest struct {
	Disk string `json:"disk"`
}

type LsblkOutput struct {
	BlockDevices []struct {
		Name       string      `json:"name"`
		Size       string      `json:"size"`
		Type       string      `json:"type"`
		MountPoint string      `json:"mountpoint"`
		Serial     string      `json:"serial"`
		Model      string      `json:"model"`
		Rota       interface{} `json:"rota"` // Can be bool or string
		Tran       string      `json:"tran"`
		Vendor     string      `json:"vendor"`
	} `json:"blockdevices"`
}

func getDisks() ([]Disk, error) {
	cmd := exec.Command("lsblk", "-J", "-d", "-o", "NAME,SIZE,TYPE,MOUNTPOINT,SERIAL,MODEL,ROTA,TRAN,VENDOR")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("lsblk error: %w", err)
	}

	var lsblk LsblkOutput
	if err := json.Unmarshal(out, &lsblk); err != nil {
		return nil, fmt.Errorf("unmarshal error: %w", err)
	}

	osMap := make(map[string]string)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	
	proberCmd := exec.CommandContext(ctx, "sudo", "os-prober")
	proberOut, _ := proberCmd.Output() 
	lines := strings.Split(string(proberOut), "\n")
	for _, line := range lines {
		parts := strings.Split(line, ":")
		if len(parts) >= 4 {
			dev := parts[0]
			name := parts[1]
			baseDev := dev
			if strings.Contains(dev, "nvme") || strings.Contains(dev, "mmcblk") {
				if idx := strings.LastIndex(dev, "p"); idx > 0 {
					baseDev = dev[:idx]
				}
			} else {
				baseDev = strings.TrimRight(dev, "0123456789")
			}
			osMap[baseDev] = name
		}
	}

	var disks []Disk
	for _, bd := range lsblk.BlockDevices {
		nameLower := strings.ToLower(bd.Name)
		if bd.Type == "loop" || strings.HasPrefix(nameLower, "zram") || strings.HasPrefix(nameLower, "zd") {
			continue
		}
		
		rotational := false
		switch v := bd.Rota.(type) {
		case bool:
			rotational = v
		case string:
			rotational = v == "1"
		case float64: // JSON numbers are often float64
			rotational = v == 1
		}

		isVirtual := strings.Contains(strings.ToLower(bd.Vendor), "virtio") ||
			strings.Contains(strings.ToLower(bd.Model), "virtio") ||
			strings.Contains(strings.ToLower(bd.Vendor), "qemu") ||
			strings.HasPrefix(nameLower, "vd") ||
			bd.Tran == "virtio"

		log.Printf("Found disk: %s (Type: %s, Tran: %s, Vendor: %s, Rota: %v)", bd.Name, bd.Type, bd.Tran, bd.Vendor, rotational)

		disk := Disk{
			Name:       "/dev/" + bd.Name,
			Size:       bd.Size,
			Type:       bd.Type,
			MountPoint: bd.MountPoint,
			Serial:     bd.Serial,
			Model:      bd.Model,
			Rotational: rotational,
			Transport:  bd.Tran,
			IsVirtual:  isVirtual,
			OS:         osMap["/dev/"+bd.Name],
		}
		disks = append(disks, disk)
	}

	sort.Slice(disks, func(i, j int) bool {
		if disks[i].Transport == "nvme" && disks[j].Transport != "nvme" { return true }
		if disks[i].Transport != "nvme" && disks[j].Transport == "nvme" { return false }
		if !disks[i].Rotational && disks[j].Rotational { return true }
		if disks[i].Rotational && !disks[j].Rotational { return false }
		return disks[i].Name < disks[j].Name
	})

	return disks, nil
}

func handleInstall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req InstallRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	log.Printf("Starting ZFS installation on: %s", req.Disk)
	installerPath := os.Getenv("ZUI_INSTALLER_PATH")
	if installerPath == "" {
		installerPath = "./install.sh"
	}

	// Use sudo for the installation script to ensure it has root privileges and access to ZFS.
	// We explicitly pass the current PATH to sudo because sudo usually resets it.
	// We also use -E to preserve other environment variables.
	cmd := exec.Command("sudo", "-E", "PATH="+os.Getenv("PATH"), "bash", installerPath, req.Disk)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Start()
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to start installer: %v", err), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(map[string]string{"status": "Installation started"})
}

func main() {
	http.HandleFunc("/api/disks", func(w http.ResponseWriter, r *http.Request) {
		disks, err := getDisks()
		if err != nil {
			log.Printf("Error getting disks: %v", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(disks)
	})
	http.HandleFunc("/api/install", handleInstall)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		frontendPath := os.Getenv("ZUI_FRONTEND_PATH")
		if frontendPath == "" {
			frontendPath = "../frontend/index.html"
		} else {
			frontendPath = frontendPath + "/index.html"
		}
		http.ServeFile(w, r, frontendPath)
	})
	log.Println("ZUI Server listening on :80...")
	log.Fatal(http.ListenAndServe(":80", nil))
}
