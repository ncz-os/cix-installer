# NCZ 26.6 (Reinhardt / Magnetar)
## CIX Sky1 (CP8180) Edge AI Appliance
> **IMPORTANT NOTE:** This operating system and hardware support matrix has only been tested on the **Minisforum MS-R1** using the **latest beta BIOS**. The beta BIOS update is highly recommended as it resolves several critical hardware initialization issues present in the factory-shipped Minisforum firmware. You can find the ARM SystemReady Beta BIOS and EFI flashing instructions in the [Minisforum MS-R1-Docs GitHub Repository](https://github.com/minisforum-docs/MS-R1-Docs/blob/main/PlayBook/MS-R1-ARMSystemReady.md).


Welcome to **NCZ 26.6**, a specialized operating system built specifically to unlock the true potential of the CIX Sky1 / CP8180 architecture (used in the Minisforum MS-R1). 

While other distributions provide basic boot capabilities, NCZ 26.6 turns this hardware into a highly optimized, turnkey AI and Orchestration Edge Server.

### What is Included?
This ISO is a Universal Boot Medium. When you boot, you can choose:
* **Reinhardt (Desktop):** A lightweight XFCE desktop environment for visual workflows.
* **Magnetar (Server):** A headless, container-optimized edge server.

---

### Hardware Support Matrix (Kernel 7.0.12-cix-sky1-next)

We have fully validated the drivers and runtime environments on this release:

#### 1. NPU (Neural Processing Unit) — **FULLY SUPPORTED**
* **Driver:** armchina_npu (In-Tree)
* **Userspace:** cix-noe-umd 3.1.2
* **Capabilities:** The NPU is restricted by the silicon to a 1GB contiguous memory window. We have successfully compiled and deployed the all-MiniLM-L6-v2 embedding model directly to the NPU.
* **Performance:** ~68 vector embeddings per second natively on silicon.

#### 2. GPU (Arm Mali-G720 MC10) — **PARTIALLY SUPPORTED**
* **Driver:** panthor (In-Tree)
* **Rendering / Video:** Fully supported. Desktop UI and amvx hardware video decoding work perfectly.
* **Vulkan Compute (LLMs):** Currently **UNSUPPORTED** for large models. The upstream Mesa panvk driver for the 5th-gen CSF architecture is still in testing. It requires massive contiguous memory allocations that clash with the kernel CMA (Contiguous Memory Allocator) pool. If you attempt to load a large LLM into Vulkan VRAM, it will instantly crash with ErrorOutOfDeviceMemory. 
* **Workaround:** Run LLMs natively on the CPU (see below).

#### 3. CPU (12-Core ARMv9) — **FULLY SUPPORTED**
* **Capabilities:** The CIX Sky1 features 8 Big cores (2.6GHz) and 4 Small cores (1.8GHz). 
* **Performance:** Using llama-cpp-python, the CPU can process Qwen2.5-Coder-7B (Q4) at roughly **7 tokens per second**. We strongly recommend binding heavy AI workloads (like LLM inference) explicitly to the 8 Big Cores using `taskset -c 0-3,8-11`.

#### 4. Wireless & Audio — **FULLY SUPPORTED**
* We have packaged the missing MediaTek MT7922 firmware blobs and corrected the ACPI ALSA bridges. WiFi, Bluetooth, HDMI Audio, and Analog Audio work out-of-the-box.

---

### Embedded AI Tools

NCZ 26.6 ships with two massive integrations built directly into the OS:

#### 1. MNEMOS (Hardware Vector Database)
NCZ 26.6 ships with **MNEMOS v6.0**, powered by PostgreSQL + pgvector. 
To utilize the NPU, we have built a custom FastAPI wrapper (cix-npu-embedder.service) that exposes the silicon as a local, OpenAI-compatible REST endpoint on port 8000. MNEMOS talks directly to this endpoint to vectorize memories instantly.

#### 2. ZeroClaw Orchestration (Hardware Isolated)
The zeroclaw orchestration agent is deployed as a Podman Quadlet (zeroclaw-agent.service). 
To ensure zero performance loss for your LLM or Database workloads, we have explicitly jailed ZeroClaw inside a cgroup bound **only to the 4 small CPU cores (CPUs 4-7)** and hard-capped it at 512MB of RAM. This cap is more than enough headroom: the agent requires less than 50MB to initialize (often idling under 10MB), and asynchronous task fan-out does not cause significant memory expansion.

---
*Built for the NCZ Fleet (2026).*

### Post-Install: Deploying Agents and MNEMOS
To keep the base operating system footprint light and completely air-gapped, we do not auto-install the heavier Python/Rust agent frameworks from the ISO.

Once your system is booted and connected to the internet, you can easily install the **MNEMOS NPU Embedder** and the **ZeroClaw** orchestration agent:

**Option 1: Using the Desktop Shortcut (Reinhardt only)**
Double-click the  script located on your Desktop.

**Option 2: Via Command Line (Magnetar / Server)**
Run the following script provided in the system tools path:


This script will automatically configure the official NCZ GitLab APT repository, download the pre-compiled  models, and launch the systemd/podman services isolated to their correct CPU cores.

### Post-Install: Deploying Agents and MNEMOS
To keep the base operating system footprint light and completely air-gapped, we do not auto-install the heavier Python/Rust agent frameworks from the ISO.

Once your system is booted and connected to the internet, you can easily install the **MNEMOS NPU Embedder** and the **ZeroClaw** orchestration agent:

**Option 1: Using the Desktop Shortcut (Reinhardt only)**
Double-click the `install_ncz_agents.sh` script located on your Desktop.

**Option 2: Via Command Line (Magnetar / Server)**
Run the following script provided in the system tools path:
```bash
sudo /usr/local/lib/cix-installer/assets/install_ncz_agents.sh
```

This script will automatically configure the official NCZ GitLab APT repository, download the pre-compiled `.cix` models, and launch the systemd/podman services isolated to their correct CPU cores.
