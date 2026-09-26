# PVE Ubuntu Server 模板

给这台 PVE (9.2.2) 做的一套「一键式」Ubuntu Server 24.04 VM 模板。

从官方 cloud image 出发，烘好 OVMF/UEFI + virtio 全套 + cloud-init 原生支持 + 常用开发工具，
转成 PVE template。之后建 VM 只需要：

* **GUI**：Datacenter → QEMU → VM Templates → `tpl-ubuntu-2404` → Create VM，填主机名和 IP，Finish，Start
* **CLI**：`new-vm.sh myapp --auto-ip` 一行搞定，输出直接给出 SSH 命令

---

## 在一台全新的 PVE 上复现

```bash
git clone <repo> && cd aistudio/pvestudio
cp conf.env.example conf.env && vim conf.env      # 至少改密码和网络

./bootstrap.sh --check      # 只体检，不改任何东西（先跑这个）
./bootstrap.sh              # 完整流程：体检 → 拉镜像 → 宿主设置 → 建模板 → 28 项验证 → 比对
```

`bootstrap.sh` 会做这些事：

| 步骤 | 内容 | 耗时 |
|---|---|---|
| 1 体检 | root / PVE / 架构 / genisoimage / 存储 / 网桥 / 磁盘余量 / 内存 / SSH 密钥 / 模板是否已存在 / 气球设置 | 秒级 |
| 2 备输入 | 没有 SSH 密钥就生成 ed25519（并打印公钥给你拷到 workstation）；下载 Ubuntu cloud image 并校验 sha256 | 0 或几分钟 |
| 3 宿主设置 | `tune-host.sh` —— 关掉 PVE 自动气球对内存的回收 | 秒级 |
| 4 建模板 | `build-template.sh` | 3-5 分钟 |
| 5 验证 | `smoke-test.sh` —— 建临时 VM 跑 28 项检查后销毁 | 3-4 分钟 |
| 6 比对 | 和 `reference/` 里的期望值 diff（自动忽略 UUID/MAC/时间戳等必然变化项） | 秒级 |

常用开关：

```bash
./bootstrap.sh --check         # 只体检，零改动
./bootstrap.sh --no-verify     # 跳过第 5 步，省 3-4 分钟
./bootstrap.sh --force         # 覆盖已存在的模板
```

### 新机器上最可能卡住的地方

* **SSH 密钥**：新装的 PVE 上 `/root/.ssh/` 通常是空的。`bootstrap.sh` 会自动生成
  ed25519 并把公钥打印出来 —— **你必须把它加到自己的 workstation 上**，
  否则 clone 出来的 VM 从外面连不进去。想用自己的密钥，建机时
  `new-vm.sh --key ~/.ssh/id_ed25519.pub`，或改 `conf.env` 的 `SSH_PUBKEY_FILE`。
* **cloud image 596MB 下载**。URL 和 sha256 都钉死在 `conf.env` 里
  （用带日期的版本目录 `noble/20260911/`，不用滚动的 `noble/current/`，
  否则同一份脚本在不同时间跑出来的镜像不一样）。指纹不符会直接报错并删掉重下。
* **genisoimage**：PVE 靠它生成 cloud-init ISO。正常装了 PVE 都有
  （`qemu-server` 包依赖它），体检会检查，缺了就提示装。
* **网桥/网关网段**：`conf.env` 的 `GATEWAY` 必须和 `BRIDGE` 的网段一致，
  否则静态 IP 的 VM 上不了网。体检会检查并提醒。
* **内存**：构建期只分配 `min(MEMORY_MB, 宿主可用/2, 4096)` M，
  所以 8G 的机器也能构建一个标称 20G 的模板（模板平时不运行，不占内存）。

### 那些 LVM 卷为什么要重新生成而不是打包带走

模板在 PVE 上体现为三个 LVM 卷，**全都是派生产物，一个都不需要导出**：

| 卷 | 大小 | 是什么 | 怎么来的 |
|---|---|---|---|
| `base-9000-disk-0` | 4M | 模板的 EFI 变量盘 | `qm create --efidisk0` 从 PVE 自带的 `/usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd` 拷一份 |
| `base-9000-disk-1` | 100G（实际 2.0G） | guest 根文件系统 | 官方 cloud image（596MB，sha256 钉死）+ `guest/provision.sh` 装 766 个包 |
| `vm-9000-cloudinit` | 4M | cloud-init 种子 ISO | PVE **每次 VM 启动时**按 VM 配置动态生成；clone 时还会给新 VMID 重新分配 |

所以 `pvestudio` 里只需要放**脚本 + 一个校验过的上游下载链接**，
不需要塞 2GB 二进制。派发体积从 ~2GB 变成几十 KB。

`reference/` 里的两个配置**只是比对用的期望值，不是用来恢复的**。
把 `expected-9000.conf` cp 回 `/etc/pve/qemu-server/` 只会得到一个
指向不存在磁盘卷的坏 VM —— VM 配置必须和真实 LVM 卷一起由脚本生成。

## 凭据在哪 / 提交安全

根目录的 `.gitignore` 只忽略 `.env` / `*.key` / `id_rsa`，**覆盖不到 `pvestudio/conf.env`**，
所以 pvestudio 自己加了 `.gitignore`。

| 位置 | 内容 | 进版本库？ | 保护方式 |
|---|---|---|---|
| `pvestudio/conf.env` | `CI_PASSWORD` **明文** | ❌ | `pvestudio/.gitignore` + 600 权限 |
| `pvestudio/conf.env.example` | 同样结构，占位符 | ✅ | 密码写成 `<改成你自己的密码>` |
| `pvestudio/reference/expected-9000.conf` | 原本含口令哈希 + 公钥 | ✅ | 已脱敏成 `<hidden>` |
| `/etc/pve/qemu-server/9000.conf` | `cipassword` 的 `$5$` 哈希、公钥 | ❌ | 仓库外；`qm config` 本来就显示 `**********` |
| `/root/.ssh/id_rsa` | 私钥 | ❌ | 仓库外（根 `.gitignore` 也有 `id_rsa`） |
| 模板磁盘镜像内 | guest 的 `authorized_keys`、`ubuntu` 口令哈希 | ❌ | 在 LVM 卷里，不随脚本派发 |

> 公钥本身不算秘密，列出来是让你知道它会跟着哪些东西走。

提交前自查：

```bash
./scan-secrets.sh              # 扫 pvestudio 目录
./scan-secrets.sh --staged     # 扫 git 暂存区的内容（提交前最该跑这个）
./scan-secrets.sh --self-test  # 验证 7 条规则本身没坏
```

这个脚本扫的是**文件内容**而不是文件名 —— `.gitignore` 按文件名匹配，
文件名干净的文件里照样可能写着口令。本仓库的 `README.md` 就曾经写着明文口令，
是写这个脚本时扫出来的（已修）。

`--self-test` 那个模式值得单独说一句：规则写成 `^-----BEGIN ...` 这种**以 `-` 开头**的模式时，
grep 会把它当成命令行选项，整条规则静默失效，脚本还会报"干净"。
所以它会显式验证每条规则能否命中样本，避免"没扫到"其实是"根本没在扫"。
（这个坑真踩到过：私钥检测规则从来没生效过。）

---

## 目录结构

```
/root/aistudio/pvestudio/
├── README.md              本文件
├── bootstrap.sh           ★ 在全新 PVE 上一键复现整套东西（先看这个）
├── conf.env               所有可调参数（规格/密码/网段/预装包）—— 不进版本库
├── conf.env.example       conf.env 的模板（这个才进版本库）
├── build-template.sh      从 cloud image 构建模板（幂等，--force 重建）
├── new-vm.sh              从模板一键建机
├── smoke-test.sh          冒烟测试：建一台临时 VM 跑 28 项验证后销毁
├── tune-host.sh           宿主内存气球设置（bootstrap 内部调，也可单独跑）
├── lib/common.sh          公共函数（IP 分配、SSH 等待、日志）
├── guest/provision.sh     guest 内部的定制脚本（装包 / SSH / 系统调优）
└── reference/             产出物的期望值快照（比对用，勿 cp 回去，详见其 README）
```

日志：`/var/log/pve-template-build.log`

脚本都用 `BASH_SOURCE` 算自己的位置，所以**整个目录可以随意搬动**，
放到任何路径下都能跑（`conf.env` 里那几处是宿主绝对路径，不是脚本位置）。

---

## 模板里有什么

| 项目 | 配置 |
|---|---|
| 系统 | Ubuntu Server 24.04 LTS (noble)，kernel 6.8 |
| 固件 | **OVMF / UEFI** (4MiB vars, Secure Boot 关) |
|  chipset | q35 |
| CPU | `host` 直通（可改成 `x86-64-v2-AES`） |
| 磁盘 | VirtIO SCSI Single，discard + iothread + SSD 模拟，100G |
| 网络 | VirtIO 网卡，vmbr0 |
| 内存 | 20G，**带气球 (balloon)** —— 宿主内存紧张时 guest 空闲内存会被回收 |
| 其他 | guest agent 开机自启、串口 (serial0)、tablet 指针、UEFI 变量盘 |
| 磁盘扩容 | clone 后 `qm disk resize` 调大，**guest 首次开机自动 growpart 铺满** |
| 身份隔离 | machine-id / SSH host key 每次 clone 重新生成，克隆不串味 |

预装包（开发测试向，**不含任何语言运行时**——node/java/go/python 建议用容器）：

```
编译:  build-essential gcc g++ make cmake pkg-config gdb
版本:  git git-lfs
网络:  curl wget rsync iproute2 dnsutils ncat socat nmap openssh-client
工具:  vim tmux htop tree jq ripgrep silversearcher-ag less file strace
压缩:  unzip zip xz-utils p7zip-full
Python: python3 python3-pip python3-venv python3-dev
系统:  qemu-guest-agent cloud-guest-utils bash-completion locales
硬件:  smartmontools nvme-cli usbutils pciutils lm-sensors
```

系统调优（可改 `guest/provision.sh` 后重建）：

* journald 限制 300M，保留 2 周——别让日志吃满磁盘
* `net.core.somaxconn=4096`、`tcp_max_syn_backlog=4096`、`fs.file-max=200000`
* apt 缓存 7 天自动清一次，禁止自动重启
* `fstrim.timer` 常开（thin provisioning 必需）
* `/etc/ssh/sshd_config.d/05-pve-template.conf`：`PermitRootLogin prohibit-password`、
  `PasswordAuthentication yes`、`ClientAliveInterval 120`（长连接不断）
* `DefaultTimeoutStartSec` 降到 90s（无外设 VM 省开机时间）

---

## 登录方式

模板里已经烘好了：

* `root` 和 `ubuntu` 两个账号的 `~/.ssh/authorized_keys` 里都有 **你这台 PVE 的公钥**
* `ubuntu` 密码 = `conf.env` 里的 `CI_PASSWORD`（**明文只存在于 `conf.env`，该文件已被 git 忽略**）
* 两边都免密 sudo

所以 clone 出来**什么都不填也能直接 SSH 进去**：

```bash
ssh -i ~/.ssh/id_rsa ubuntu@<IP>     # 从你的电脑上要把自己的公钥填进去
ssh -i /root/.ssh/id_rsa ubuntu@<IP> # 在 PVE 上直接连
```

> 在 GUI 建机时，Cloud-init 页的 **SSH Keys** 字段可以再叠加任意公钥，会和模板里那份共存。
> 但注意：设了 `cicustom` 的话 PVE 会忽略 `ciuser/sshkeys`，本模板没用 `cicustom`，所以不受影响。

> 🔒 **密码只放在 `conf.env` 里，不要写进任何会被提交的文件。**
> `conf.env` 已被 `pvestudio/.gitignore` 忽略（600 权限），
> 进版本库的是脱敏的 `conf.env.example` 和 `reference/expected-9000.conf`
> （后者的 `cipassword` / `sshkeys` 已替换成 `<hidden>`）。
> 提交前可以跑 `./scan-secrets.sh` 确认。

**改密码**：`vim conf.env` 改 `CI_PASSWORD` 然后 `./build-template.sh --force`；
或者建机时 `./new-vm.sh myapp --password '新密码'`。

**关掉密码登录**：在 guest 里 `sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/05-pve-template.conf && sudo systemctl reload ssh`。

注意是 `05-` 这个文件。改成 `60-` 会排在 cloud-init 的 `50-cloud-init-settings.conf` 之后，
于是 `PasswordAuthentication no` 先被取到，你的修改不生效（原因见下面第 9 条）。

---

## 用法一：GUI

1. `https://<PVE>:8006` → Datacenter → QEMU → **VM Templates** → 选中 `tpl-ubuntu-2404` → **Create VM**
2. **General** 页：VMID（留空自动分配）、Hostname（VM 名字）→ Next
3. **OS** 页：确认 "Linux / 2.6 - 3.x / 64-bit"，Disk 用模板默认的 100G → Next
4. **System** 页：CPU / Memory / Boot disk 都能改 → Next
5. **Disks** 页：默认 `scsi0` 已就绪，可加数据盘 → Next
6. **Network** 页：默认 virtio/bridge=vmbr0 → Next
7. **Cloud-init** 页：勾 **Enable Cloud-Init**
   * IP Address Mode：`NoCloud` → 选 `dhcp` 或填静态 `192.168.0.x/24`（网关/DNS 单独填）
   * SSH Keys：想加公钥就贴进来
   * User / Password：默认已是 `ubuntu` / 模板构建时 `conf.env` 里设的那个密码
     （PVE 会把 `conf.env` 的值继承下来，不用重填）
8. **Finish** → Start

⚠️ 磁盘那一步**不要改小**——raw 盘没法缩容。模板磁盘是 100G，clone 只能往大调。

---

## 用法二：命令行一键

```bash
cd /root/aistudio/pvestudio

./new-vm.sh myapp --auto-ip                  # 自动挑空闲静态 IP（推荐）
./new-vm.sh myapp                            # DHCP
./new-vm.sh myapp --ip 192.168.0.120         # 指定静态 IP
./new-vm.sh myapp --dhcp --cores 8 --mem 8192
./new-vm.sh db-01 --disk 200G --data-disk 500G --snapshot
./new-vm.sh myapp --no-start                 # 只建不启动
./new-vm.sh myapp --key ~/.ssh/id_ed25519.pub --password '别的密码'
```

跑完直接输出登录命令。常用选项：

| 选项 | 说明 |
|---|---|
| `--auto-ip` | 从 `conf.env` 的 `IP_POOL` 里挑一个真正空闲的（会 ping + 查 ARP 表） |
| `--dhcp` / `--ip A.B.C.D` | 网络模式 |
| `--cores N` `--mem MB` | 覆盖默认 4C / 20480M |
| `--disk 200G` | 只能在模板的 100G 基础上往大调 |
| `--data-disk 500G` | 额外加一块 scsi1 裸盘（不格式化） |
| `--snapshot` | 建完打一个 `init` 快照 |
| `--key FILE` | 用别的公钥（可以贴多行） |
| `--no-start` | 只创建不启动 |

`--auto-ip` 怎么判断「空闲」：先看所有 VM 配置里已占用的 IP，再 ping 探活，
**并且**只要 ARP 表里还有 MAC 记录就跳过（对方可能开着防火墙不回 ICMP）。
所以它会跳过 `.100` `.101` `.103` 这种「有人但不回 ping」的地址。

装个 alias 变成真正的单命令：

```bash
echo "alias newvm=/root/aistudio/pvestudio/new-vm.sh" >> ~/.bashrc
newvm myapp --auto-ip
```

---

## 验证模板

```bash
./smoke-test.sh              # 建临时 VM，逐项检查 20+ 项，然后销毁
./smoke-test.sh --keep       # 保留下来手动看
./smoke-test.sh --ip 192.168.0.150   # 指定静态 IP 测
```

检查项包括：磁盘是否铺满、machine-id 是否重新生成、SSH host key 是否存在、
sudo/root 免密、guest agent 双向连通、预装包在不在、出网正常、密码登录配置、
**内存是否真的到位（等气球涨到 maxmem 再判定）**、启动过程有无 OOM。

> 28 项全部通过才算模板可用。测试完自动销毁（会先 `qm stop` 再 `qm destroy`——
> `qm destroy` 对运行中的 VM 是直接失败的）。

---

## 重建 / 改配置

所有可调项都在 `conf.env`，改完重建：

```bash
vim conf.env            # 规格、密码、IP 段、时区、预装包、swap...
./build-template.sh --force
```

`--force` 会删掉旧的模板 VMID（含磁盘）重头构建，约 8-12 分钟。
`./build-template.sh --keep` 会保留构建中间态供调试，但**那样得到的 VM 不能当模板用**。

---

## 这台机器上的实际约束（重要）

### 1. PVE 会偷偷把你的内存收回去（重要）

这是本次配置里最值得注意的一个坑，也是实测踩到的。

PVE 8.2+ 的 `pvestatd` 有**自动气球**功能，算法在 `pvestatd.pm:296-320`：

```
goal = memtotal * ballooning-target / 100 - memused

goal > 0  ->  宿主有富余，把内存【送给】VM，直到各自 maxmem
goal < 0  ->  宿主被 VM 占太多，从 VM【收回】内存，每轮 100MB 逼近 balloon 地板
```

PVE 默认 `ballooning-target = 80`。VM 吃满后 `memused` 上到 80% 以上，`goal` 转负，
PVE 就一轮轮往回收，**把每台 VM 压到它的 `balloon` 地板**。

实测（一台配了 4096M 的 VM）：

| 时刻 | guest 实到内存 |
|---|---|
| 刚启动 | 4096 M |
| 1 分钟后 | 1896 M |
| 3 分钟后 | 948 M（已到地板） |

配 2048M 的那台直接被压穿，**guest 在启动阶段 OOM**，
`systemd generator`（`sd-gens`）被杀，boot 根本完不成：

```
Out of memory: Killed process 277 ((sd-gens)) total-vm:196688kB, ...
virtio_balloon virtio0: Out of puff! Can't get 1 pages
```

也就是说，模板里写 `memory: 20480` 是**名存实亡**的，guest 拿不到 20G。

**处理：**

1. **节点级**：`ballooning-target = 100` —— `goal` 恒为正，每台 VM 稳定在 `maxmem`，
   也就是你写的 `memory` 值。VM 实到内存 = 配置值。

   ```bash
   ./tune-host.sh            # 应用
   ./tune-host.sh --show     # 看现状 + 各 VM 实到内存
   ./tune-host.sh --revert   # 恢复 PVE 默认 80
   ```

   ⚠️ **改完必须 `systemctl restart pvestatd`**——运行中的 pvestatd 会缓存节点配置，
   改文件不重启是没反应的（这个也踩了）。重启后 VM 内存每轮 100MB 往回涨，
   **2-4 分钟才到满**，属正常，别以为没生效。

   ⚠️ **代价**：内存不再自动回收。所有 VM 的 `memory` 之和必须 ≤ 宿主物理内存，
   否则宿主吃 swap 甚至 OOM。31G 的机器按 20G 一台，最多同时跑 1 台大的。
   气球设备还在，GUI 里可以手动调小。

2. **每台 VM**：`balloon` 地板设为内存的 25%（20480M → 5120M）。
   万一以后有人把 `ballooning-target` 改回去，VM 最多被压到 1/4，不会压穿。

> ⚠️ `qm set --balloon N` 里的 N 是**最小内存 MiB**，不是 CLI 帮助里写的
> "target RAM"。源码 `QemuServer.pm:2538` → `balloon_min = balloon * 1024*1024`。
> 写 `--balloon 1` 等于允许把 VM 压到 1 MiB。本模板早期版本就踩了这个。
>
> 想要更硬的做法：**配置里不写 `balloon` 这个键**，自动气球会直接跳过这台 VM
> （`AutoBalloon.pm:96` 的 `next if !$d->{balloon_min}`）。代价是没有气球设备，
> GUI 里运行时不能再拖内存滑块。

### 3. 内存下限 4096M

`new-vm.sh` 会拒绝低于 `MIN_MEM_MB`（默认 4096）的 `--mem`。
实测 2048M 的 clone 起不来，4096M 正常——这套模板装了 766 个包，
systemd generator 阶段内存压力不小。

### 4. clone 是全量拷贝，100G 盘约 33 秒

`local-lvm` 是 LVM-thin，PVE 的 `LvmThinPlugin.pm` 里写死
`die "unsupported format"`——**只支持 raw**。raw 盘没法做 linked clone（零拷贝）。

实测 100G 模板 clone 一台 **约 30 秒**（`qemu-img convert` 走稀疏读写，
模板里只有 2.0G 真实数据，所以比想象的快）。可以接受。

建机到能 SSH 的总耗时实测 **约 50 秒**：clone 30s + 启动 20s。
磁盘越大这个数越大，模板实际占用小所以影响有限。

PVE 每次 clone 会刷一堆 `WARNING: Sum of all thin volume sizes (600 GiB)
exceeds the size of thin pool` —— 那是**超卖警告，不是错误**。
thin provisioning 下没问题，除非你真把盘写满了。

想换成 linked clone（秒级、零额外空间）需要 qcow2 存储，
而 `pve` 这个 VG 只剩 **16G 空闲**，不够。加盘或新建 zfs/dir 存储才行。

### 5. 20G 内存 / 100G 磁盘 是默认值，不是能同时跑的台数

宿主只有 **6 核 / 31G 内存 / 141G thin pool**。

* 内存：两台 20G 的 VM 就超了。批量建机时记得 `--mem` 调小，或者别同时开
* CPU：6 核分给多台 4 核 VM 会超分
* 磁盘：thin pool 141G，100G × 2 台虽然不会立刻满（稀疏），但真写满两台就爆了

模板的规格只是**默认值**，随手改：

```bash
./new-vm.sh a --mem 4096 --cores 2 --disk 40G
```

### 6. 磁盘只能往大调

raw 盘不支持缩容。`new-vm.sh` 会拦住比模板小的 `--disk`。
磁盘不够用就加数据盘（`--data-disk`）或建新模板。

### 7. guest 里网卡叫 `eth0`

PVE 生成的 netplan 配置（network-config v2）会写 `set-name: eth0`，
所以 guest 里 `ip addr` 看到的是 `eth0`，不是 `ens3`/`enp0s2`。
这是 PVE cloud-init 的标准行为，写脚本时注意。

### 8. 构建 IP 和一个遗留设备

`conf.env` 里的 `BUILD_IP=192.168.0.249` 只在构建模板时用（静态 IP，方便 SSH 进去定制），
构建结束就作废，不会进模板。

另外扫到 `192.168.0.200` 上有个 MAC 为 `bc:24:11:19:17:af` 的设备——
和之前手工做的那个 `cidata.iso` 里硬编码的 MAC 一致。
那台 VM 不在本节点的 `/etc/pve/qemu-server/` 里（可能迁走了或配置丢了）。
如果确认是废弃的，`ip neigh` 刷一下或重启网络设备，ARP 表清干净后 `.200` 就能用了。

---

## 一些细节说明

### 模板为什么是 UEFI 而不是 BIOS

Ubuntu 24.04 cloud image 两个都支持，但 UEFI 是官方主推路径，后续版本的
cloud image 只会越来越完善 UEFI 支持。BIOS 模式已经算 legacy 路径了。

### 为什么模板磁盘给到 100G

按你要求设的默认值。代价是 clone 走全量拷贝。嫌慢就在建机时用
`--disk 20G`（比模板小不行）—— 所以真要变小得改 `conf.env` 的 `DISK_SIZE`
重新构建模板。想让 clone 秒级的话，可以把 `DISK_SIZE` 设成 20G 重建，
然后建机时统一 `--disk 100G`（growpart 会自动铺满，效果一样）。

### cloud-init 的工作方式

模板里有个 `ide2 local-lvm:cloudinit,media=cdrom` 的「云盘」。
**这不是真的 ISO 文件**——PVE 在每次 VM 启动时根据 VM 配置动态生成一个
4MiB 的 ISO 塞进去（里面是 `user-data` / `network-config` / `meta-data`），
停止后可以随便删。

所以你在 GUI Cloud-init 页或 `qm set --ipconfig0` 里改的东西，
**下次开机才生效**。改完不用重建模板，也不用重新 clone。

hostname 来自 VM 名字（`--name`），不是 cloud-init 页的 Hostname 字段
（PVE 拿 `name` 优先，见 `Cloudinit.pm` 的 `get_hostname_fqdn`）。
所以想让 hostname 变，就改 VM 名字。

### 六个非直觉的行为（构建脚本踩过的坑）

**1. `qm set --sshkeys` 收的是文件路径，不是密钥内容**

```bash
qm set 100 --sshkeys /root/.ssh/id_rsa.pub              # 对
qm set 100 --sshkeys "$(cat /root/.ssh/id_rsa.pub)"     # 错
#   -> can't open 'ssh-rsa AAAA...' - No such file or directory
```

底层属性是 urlencoded 字符串，但 CLI 层会替你读文件并编码。

**2. `cloud-init status` 在 degraded 时退出码也非 0**

输出是 `status: done`，退出码却是 2（因为 `extended_status: degraded`）。
如果用 `state=$(cmd) || state=""` 去兜 `set -e`，那行会把**已经拿到的输出覆盖成空**，
在轮询里就变成永远等不到。正确做法是只读 stdout 文本、不看退出码：

```bash
state=$(cmd 2>/dev/null | sed -n 's/.*status: //p') || true
case "$state" in done|degraded*) break ;; esac
```

**3. 删掉 SSH host key 后，当次会话不能再开新连接**

Ubuntu 24.04 的 sshd 是 **socket 激活**（`ssh.socket`）：每个新连接都起一个
全新 sshd 进程、从磁盘重新读 host key 文件。文件一删，已建立的会话还能跑完，
但任何新连接立刻 `Connection reset by peer`。

所以清理流程必须**在同一个 SSH 会话里做完，host key 放最后一条命令**。
`build-template.sh` 里的清理脚本用 base64 传输，就是为了避开多层引号转义。

### 为什么 PVE 那边 cloud-init 状态显示 degraded

PVE 的 `Cloudinit.pm` 生成的 user-data 写的是 `user: <name>`（标量形式），
Ubuntu 24.04 装的 cloud-init 26.1 已废弃这种写法，要求用 `users:` 列表：

```
DEPRECATED: 'user' of type string is deprecated in 22.2 and scheduled to be
removed in 27.2. Use 'users' list instead.
```

所以状态是 `extended_status: degraded done`。**功能完全正常**——用户建好了、
公钥装好了、密码设好了——只是状态码难看 + 日志里两条 DEPRECATED。
这是 PVE 上游的事。想彻底消掉只能改用 `cicustom` 自己提供 user-data，
但那样 PVE 会忽略 GUI 里的 `ciuser`/`sshkeys` 字段，不划算，本模板没这么做。

### qemu-guest-agent 在 Ubuntu 上是 static 单元

`systemctl enable qemu-guest-agent` 在 Ubuntu 24.04 上是**空操作**——
这个单元没有 `[Install]` 段，靠 D-Bus 按需激活，`is-enabled` 报 `static`。
后果是 clone 出来的 VM 开机时 agent 不一定起，PVE 第一次查询要等 D-Bus 激活，容易超时。

`guest/provision.sh` 里做了兜底：检测到 `static` 就手动往
`/etc/systemd/system/multi-user.target.wants/` 挂软链，保证开机必起。

### 9. sshd 的 drop-in 文件名决定谁生效

`sshd_config.d/*.conf` 按 glob 顺序读取，而 sshd 的规则是
**第一个取到的值生效**（不是最后一个覆盖）。

Ubuntu cloud image 里有 cloud-init **每次开机都会重写**的
`50-cloud-init-settings.conf`，内容是 `PasswordAuthentication no`。
所以想开启密码登录，光写一个 `60-pve-template.conf` 是**没用的**——
`50-` 排在 `60-` 前面，`no` 先被取到，你写的 `yes` 直接被忽略。

实测踩过：`sshd -T` 显示 `passwordauthentication no`，而文件里明明写着 `yes`。

本模板用的是 `05-pve-template.conf`（排在 `50-` 前面），所以：

* 密码登录稳定开启
* 即使以后 cloud-init 每次开机重写 `50-`，也压不住 `05-`
* 开机时脚本会用 `sshd -T` 打印实际生效值，不看文件只看运行态

完整 drop-in 内容见 `guest/provision.sh`：

```
PermitRootLogin prohibit-password   # root 只能 key 登录，不给 root 密码
PubkeyAuthentication yes
PasswordAuthentication yes          # 固定密码通道
ClientAliveInterval 120             # 长连接不断（12 分钟一次心跳）
```

### 10. 读 qga 输出别写死正则

`qm guest cmd <vmid> network-get-interfaces` 返回的是**缩进过的 JSON**，
冒号两边有空格：

```json
"ip-address" : "192.168.0.106"
```

写成 `"ip-address":"` （没空格）就永远匹配不上，表现为
「VM 明明拿到 IP 了，脚本却说没拿到」。

另外新版 QGA 的地址在 `ip-addresses` 数组里，老版是顶层 `ip-address`。
`lib/common.sh` 的 `qga_first_ipv4()` 两种都认，还过滤掉 `127.0.0.1`。

### 11. 磁盘自动扩容怎么工作的

`guest/provision.sh` 确认了 `growpart` 存在（`cloud-guest-utils`），
并在需要时打开 `cloud.cfg` 的 `resize_rootfs`。
之后每次 clone 出来的 VM 首次开机，cloud-init 的 `cc_growpart` +
`cc_resizefs` 会把分区和文件系统铺到整盘。扩容是开机自动的，不用手动干预。

### 密码策略

* `ubuntu` 有固定密码，`PasswordAuthentication yes`
* `root` **只允许 key 登录**（`PermitRootLogin prohibit-password`），没有 root 密码
* 这是台内网 homelab 的取舍。要更严就关掉密码登录，或改 `conf.env` 里的密码
* `conf.env` 是 0600 吗？不是——里面存着明文密码，记得 `chmod 600 conf.env`

### 备份

这台 PVE **没配任何备份**（`/etc/pve/jobs.cfg` 是空的）。
模板本身坏了可以重建，但跑起来的数据 VM 没有任何保护。
建议加个定时任务：

```bash
pvesh create /cluster/backup --vmid 9000 --storage local --mode snapshot \
  --schedule "daily 02:00" --enabled 1
```

（`local` 只有 53G，备份要放这里；或者建个远端 PBS/NFS 存储。）

---

## 常用运维命令

```bash
qm list                        # 所有 VM
qm list --filter template      # 只看模板
qm config 9000 | grep -E "cores|memory|scsi0|net0"   # 看模板配置

# 进某台 VM 的控制台
qm terminal 101
# 或看串口日志
qm start 101 >/dev/null; qm console 101

# guest agent
qm guest cmd 101 ping
qm guest cmd 101 network-get-interfaces     # 问 VM 自己的 IP
qm agent 101 ping                            # 另一种写法

# clone 出问题看 cloud-init 日志（在 guest 里）
sudo tail -100 /var/log/cloud-init-output.log
cloud-init status --long

# 销毁
qm destroy 101 --purge --destroy-unreferenced-disks 1
```

---

## 怎么彻底删掉这套东西

```bash
qm destroy 9000 --purge --destroy-unreferenced-disks 1   # 删模板
rm -rf /root/aistudio/pvestudio /var/log/pve-template-build.log
```
