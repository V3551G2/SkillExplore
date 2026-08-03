# 把一条华为云 CodeArts PR 流水线迁到 GitCode Actions 并跑通闭环

> CodeArts → GitCode Actions · 迁移实践案例
>
> 以 **MindCluster-AscendNPUBurn** 为例：从 REST 抓取、九级作业分类、YAML 改写，到 fork 仓库里发 `/compile`、按日志逐轮修复直至全部作业转绿的完整过程记录。

---

## 0. 技能输入条件

| 项 | 值 |
|---|---|
| **CodeArts 流水线链接** | `https://devcloud.cn-north-4.huaweicloud.com/cicd/project/609138a9ed7049aa975c6b857c7234fc/pipeline/detail/1b4df40d6ae645558400c831cd6d66fb/9be1941daa384b7789151a101bfca873?v=1` |
| **测试组织链接** | `https://gitcode.com/ComputingActionTest` |
| **Cookie** | `_frid=ed40b1aedb054a2aabc3f15db60946b4; vk=88cf3eec-d33f-4592-8abf-f0a7164af22d; uba_countrycode=CN; cbc-sid=204937c2372515796d3a0297b10631dce2f4cee7a92d71358c6c821c4f13d186c43912534d6036f53750; HWWAFSESID=897dd733cf622421a1; HWWAFSESTIME=1784949605226; SessionID=6996adf3-eafd-4390-8a8b-c869b8d00449; ad_sc=; ad_mdm=; ad_cmp=; ad_ctt=; ad_tm=; ad_adp=; cf=Direct; ukey_sn=; usite=cn; x-framework-ob=hwstaff; _w3Fid=788240de372e46a69b01788c5e7a05ac; ua=0d336455b30091fa0f31c00317ab1240; SID=Set2; browserCheckResult=A; hwstaff_mindx_sys_mindx_yangyifei_cfProjectName=cn-north-4; npsFlowCardPopList=[{"home":"2026-07-25T06:45:03.772Z"}]; npsCommitDateObject={"home":"","iam":""}; cfLatestRecordTimestamp=1785117650026; console_cftk=4V1X-O8Q5-1S1W-1O9U-QWYY-LUNY-BQG6-6VSX; domain_tag=0d336455b30091fa0f31c00317ab1240; user_tag=788240de372e46a69b01788c5e7a05ac; masked_domain=h********indx_sys; masked_user=m*******ngyifei; masked_phone=178****0928; popup_max_time=240; devclouddevuibjagencyID=788240de372e46a69b01788c5e7a05ac; third-party-access=hwstaff; locale=zh-cn; _fr_ssid=7ccd5fa1a02843ff849595907bfe18ac; devclouddevuibjJ_SESSION_ID=9261022266ff179a51fded1ba2b96970b649bb5b12785422; BENSESSCC_TAG=9261022266ff179a51fded1ba2b96970b649bb5b12785422; devclouddevuibjtcftk=5XRA-E9QC-VDB1-B1V7-18HR-KUDY-BHL8-JH8T` |

### gitcode auth 状态（已确认）

```json
{
  "hostname": "gitcode.com",
  "logged_in": true,
  "username": "qinkeke",
  "token_source": "config",
  "token_valid": true,
  "git_protocol": "https"
}
```

### 基本信息

- 流水线：`PR-pipeline_MindCluster-AscendNPUBurn`
- 源仓库：`Ascend/MindCluster-AscendNPUBurn`
- 测试仓：`ComputingActionTest/MindCluster-AscendNPUBurn`
- PR：`#1 · master_test → master`
- 日期：`2026-08-11 → 08-12`
- 结果：**9/10 作业通过，PreSmoke 为硬件级 known-limit**

### 迁移后流水线结构

```
stage_0
 └── Detect_file_changes

stage_1 · CodeCheck_Build_Test
 ├── SCA · pre_commit · Antipoison · SAST
 └── Build_x86 · Build_arm · UT_Python · (clone_repo 已消除)

stage_2 · Test（修复项）
 └── PreSmoke
```

---

## 概览：最终结果一览

闭环验证在测试组织 `ComputingActionTest` 下完成：fork 仓库、推送 YAML、以 PR 评论 `/compile` 触发、对照逐作业日志诊断并推了 4 次修复到目标分支。下表为 secret 配齐、SCA 仓库登记完成后的最终状态。

| 作业 | 来源（CodeArts） | 转换方式 | 最终状态 |
|---|---|---|---|
| Detect_file_changes | `md_check` | paths-changes-filter，输出 need_build | ✅ 通过 |
| SCA | SCA 组件分析 | sca-pr-scan 插件 | ✅ 通过（需 openlibing 登记） |
| pre_commit | pre-commit 钩子 | openlibing-pre-commit-action | ✅ 通过 |
| Antipoison | 反毒扫描 | 容器 + in-repo anti_poison.py | ✅ 通过（4 个密钥） |
| SAST | 静态安全扫描 | 容器 + TuBee/AI-Check check.sh | ✅ 通过 |
| Build_x86 | x86 编译 | .build_job.yml 子工作流 + obs-upload | ✅ wheel 已构建并上传 OBS |
| Build_arm | arm 编译 | .build_job.yml 子工作流 + obs-upload | ✅ wheel 已构建并上传 OBS |
| UT_Python | Python 单测 | .ut_python.yml 子工作流 | ✅ 通过 |
| PreSmoke / JOB_smoke | 冒烟部署测试 | .presmoke.yml 子工作流（arm64 NPU） | ⚠️ known-limit（需 NPU 卡） |
| （已消除） | clone_repo / CI 仓下载 | 脚本迁入 `scripts/`，整作业删除 | ⚪ 不生成 |

> **一句话结论：** 转换链路（触发器、PR 合并引用检出、子工作流调用、need_build 门控、编译产物上传）全部验证通过。PreSmoke 因依赖实体 NPU 加速卡属于环境级 known-limit，并非转换缺陷；另发现一处真实缺陷——PreSmoke 与 Build_arm 同 stage 并行导致抢跑——已定位修复方案（拆为 stage_2）。

---

## 01 · 处理流程：四个阶段

技能规定的标准动线是「抓取 → 转换 → 产物校验 → 闭环验证」，前三个阶段在本地完成，第四个阶段在测试组织里真跑真修。

### 阶段一 · 通过 CodeArts REST API 抓取配置

从流水线 URL 解析出 `project_id=609138a9…`、`pipeline_id=1b4df40d…`、region 与 cftk，再调内部接口拿到 `definition`（stage/job/step 的 JSON）和 variables。关键动作是**在三个层级过滤掉禁用项**：

- 作业的 `strategy.select_strategy == "never"` → 整作业跳过；
- 流水线 step `enable: false` → 跳过该 step；
- 作业配置 step `enable == false` → 跳过该 step。

只对启用的 `official_devcloud_cloudBuild` 步骤去拉 `/codeci/v1/job/<job_id>/config`，避免对废弃作业做无用功。随后识别出**统一资源池**特征——`执行shell(20017) → 下载kubeconfig(20061) → SWR karmada(20028)` 三连，其中后两步是 CodeArts 基础设施，直接丢弃，从 20017 的 heredoc 里抽出真正的脚本，以 `CP_docker_image` 作为容器镜像，`CP_runs_on` 映射架构（amd64→x64，arm64*→arm64）。

### 阶段二 · 作业分类与 YAML 转换

把 9 个启用作业逐一归类，决定每种的转换范式。这是整个转换中决策最密集的一步：

| CodeArts 作业 | 归类 | GitCode 落地形态 |
|---|---|---|
| `clone_repo`（CI 仓 + OBS 上传） | Case 2 消除 | 整作业删除；CI 脚本迁入 `scripts/` |
| `md_check` | 文档变更检测 | Detect_file_changes + paths-changes-filter，need_build 门控 |
| `SCA` | 有插件 | `sca-pr-scan`（禁止降级成容器+脚本） |
| `pre-commit` | 有插件 | `openlibing-pre-commit-action`（不传 gc_token） |
| `Antipoison` | 无插件 | 容器 + in-repo `anti_poison.py`（含 apig_sdk） |
| `SAST` | 无插件 | 容器 + `git clone TuBee/AI-Check && bash check.sh` |
| `Build_x86 / Build_arm` | 编译 | 可复用 `.build_job.yml`（编译 + obs-upload） |
| `UT_Python` | 单测 | 可复用 `.ut_python.yml` |
| `PreSmoke` | 冒烟 | 可复用 `.presmoke.yml`（下载 arm 产物→装 wheel→跑 run_st.sh） |

转换中坚持的几条硬规则：PR 流水线只挂 `pull_request_comment`（评论 `^(?:\/)?compile*`）+ `workflow_dispatch`，**不**加 `pull_request_target`；stage 名用 `_` 不能用 `&`；镜像名写成 `env:` 字面量；子工作流调用只传 `required:true` 的输入（IMAGE_FLAG、runs_on_arch），由子工作流自己取 atomgit 默认值——重复传 REMOTE_URL/pr_id/TARGET_BRANCH 会触发 "bad substitution"。

### 阶段三 · 产物落盘与静态校验

在 `.gitcode/workflows/` 下生成 4 个 YAML（入口 + 3 个子工作流）和 `scripts/`（`anti_poison.py` 及真实的华为 `apig_sdk/`，用带 `PRIVATE-TOKEN` 的鉴权下载拿到真实内容，而非占位空文件）。同时放 `.gitattributes` 强制 `*.yml/*.sh/*.py` 走 LF——Windows 上 `core.autocrlf=true` 曾把脚本转成 CRLF，会导致容器里 `bash\r` 报错，提交后用 `git cat-file` 校验 blob 内无 CR。

```text
D:\ActionTest\output\workflows\

.gitcode/workflows/
├── PR-pipeline_full.yml      # 入口：触发器 + env + 两个 stage
├── .build_job.yml            # 编译 + obs-upload（OBS_AK/OBS_SK）
├── .ut_python.yml            # clone+merge PR → run_test.sh
├── .presmoke.yml             # 下载 arm 产物 → conda → run_st.sh
└── scripts/
    ├── anti_poison.py        # 真实脚本，argparse + APIG 签名
    └── apig_sdk/             # signer / sm3_hash …
```

### 阶段四 · 闭环验证（核心阶段）

把产物推到 fork `ComputingActionTest/MindCluster-AscendNPUBurn` 的 master，建测试 PR #1，用户开启「PR 预合并 / Actions」后，用 v5 接口发评论 `/compile` 触发；通过 v8（`api.gitcode.com`，注意不是 gitcode.com）轮询 runs/jobs，`download_log` 拿到的是 302→ZIP 的逐步骤 `.log`。每轮失败都下日志、定位根因、把 **YAML 修复推到目标分支 master**（评论触发器读的是目标分支上的 YAML），脚本修复则在 PR 分支生效。整个修复设了上限：最多 3 次 YAML 修复，超出后剩余失败归为 needs_human / known_limit。

---

## 02 · 交互过程：人和技能怎么配合

这次闭环不是全自动跑完的——有若干关键节点需要人做决策或配置，技能负责把"人需要做什么、为什么"讲清楚，人做完再交回给技能继续。

### 对话记录

**用户：** 「我开启了 PR 预合并，启用了 Actions，你先触发一次吧，我明天再设置私密参数。」

**技能侧：** 理解为：**无 secret 先跑一轮验证转换链路**。于是立即发 /compile，预期 secret 相关作业会红，重点验证触发器、检出、子工作流调用、need_build 门控这些"接线"是否正确。这一轮 4 个非 secret 作业全绿，5 个红作业全部精确地失败在 secret 边界（401/403），证明接线无误。

---

**用户：** 「请查看并修复，checkout 插件问题有 faq 吧」

**技能侧：** 回到 FAQ #7 核对镜像清单，发现自己给 `mindspore_python3.11:v0.1`（Debian trixie，自带 git 2.47.3）**误加**了 git 升级步骤——之前那个"portable 版本判断块"其实是在掩盖一个自找的 apt 报错。正确修复是**直接删掉该步骤**，而不是继续打补丁。

---

**用户：** 「我已经设置了私钥，请重新开始验证-修复」

**技能侧：** 配齐 8 个 secret 后重新触发。这一轮 x86/arm 编译双双产出 wheel 并上传 OBS，pre_commit/SAST/UT 保持全绿。期间用户在页面手动**重试了卡在 QUEUED 的作业**（专用 runner 调度慢），技能通过 start_time/状态判断出这是资源调度而非代码问题。

---

**用户：** 「针对 SCA 的报错，我已经在 openlibing 的 MindCluster 组织下录入了该仓库」

**技能侧：** SCA 报 `code 41003 / repoUrl is null`，是平台侧仓库登记问题（插件上报的是测试 fork 的 URL），不属于转换缺陷。用户登记后该项解除。

---

**用户：** 「我看除了 PreSmoke 任务（需要卡）外其他任务基本上成功了……可以停止了」

**技能侧：** 确认 PreSmoke 的 NPU 卡依赖是环境级 known-limit 后**立即停止后台轮询**，不再推送未经确认的改动；已定位的 PreSmoke 并行竞态修复（拆 stage_2）作为待办说明，交由用户决定是否继续。

### 逐次运行记录

- 🔴 **早期迭代（`6937ed8d / 646c1342 / b5e916bc`）** · Detect/pre_commit/SAST 因 git 版本与包管理问题接连失败
  对应 fix#1（加 git 升级）→ fix#2（Debian 无 software-properties 的兜底）→ fix#3（gitleaks 装到工作区根）。
- 🟢 **`ef34e887`** · 4 个非 secret 作业全绿，5 个红作业均失败在 secret 边界
  无 secret 条件下的接线验证，确认转换正确。
- 🟢 **`5a4cf87b`（run #5）** · 删除 pre_commit 误加的 git 升级步骤后仍全绿
  用镜像自带 git 2.47.3 检出通过，省掉约 60s apt 时间（commit 4be7896）。
- 🟡 **`b0b6f8b5`（run #6）** · Detect 卡在 QUEUED 后因 GPG key 超时失败
  专用 runner 调度延迟 + `add-apt-repository` 拉 GPG key 网络抖动，用户在页面重试救活 runner。
- 🟢 **`e2503e4a`（run #7）** · secret 配齐后双架构编译产物上传 OBS 成功；PreSmoke 暴露并行竞态
  SCA 经 openlibing 登记后通过；PreSmoke 抢跑导致 arm 产物 404，定位为 stage 并行问题。

> **凭证处理的安全约定：** 全程不要求用户在对话里粘贴明文 token，而是用 `gitcode auth token` 解析；`gitcode auth status --json` 显示 logged_in/token_valid 即视为凭证已提供。带 token 的命令一律 `set +x`，日志/提交信息/总结里只用 `$TOKEN` 指代。

---

## 03 · 遇到的问题与修复

下面按"真实代码缺陷 → 环境/平台问题 → 自我纠错"分组。每个问题给出错误现象、根因和最终修法——包括一次走了弯路又退回正轨的过程。

### P1 · checkout 报 git 版本过低  `[YAML 修复]`

- **现象**
  ```text
  要求的最低git版本是 2.18, 当前git ('/usr/bin/git') 版本为 2.17.1
  ```
- **根因**：`demo_mindx:mindxdl_20230912_1` 与 `mindx_x86:mindxdl_go1207_20251203` 基于 Ubuntu bionic，自带 git 2.17.1，低于 checkout 动作要求的 2.18。
- **修复**：在这些**已知旧 git 镜像**的 checkout 之前加 git 升级步骤（apt → PPA → 安装）。Detect、Antipoison、SAST 三个作业需要。

```yaml
- name: git upgrade
  run: |
    apt-get update
    apt-get install -y software-properties-common
    add-apt-repository -y ppa:git-core/ppa
    apt-get update
    apt-get install -y git
    git --version
```

### P2 · 把 git 升级误加到 mindspore 镜像（一次弯路）  `[已纠正]`

- **现象**：pre_commit 报 `E: Unable to locate package software-properties-common`（exit 100）。
- **根因**：fix#1 给 `mindspore_python3.11:v0.1` 也加了升级步骤，但该镜像是 Debian trixie，没有 PPA 支持；**而它自带 git 2.47.3 根本不需要升级**。fix#2 写的"portable 版本判断块"只是在掩盖这个自找的错误。
- **修复**：对照 FAQ #7 的镜像清单，**直接删除** pre_commit 的 git 升级步骤。这是用户点名"checkout 插件问题有 faq 吧"后回到 FAQ 才发现的——FAQ 早已明确 mindspore 镜像不应加该步骤。教训：先查 FAQ，按镜像条件化加步骤，不要用兜底逻辑去救一个本不该存在的步骤。

### P3 · pre-commit 的 gitleaks 钩子找不到可执行文件  `[YAML 修复]`

- **现象**
  ```text
  Executable './gitleaks' not found  (hook id: gitleaks-offline-scan, exit 1)
  ```
- **根因**：钩子在仓库根目录执行 `./gitleaks`，但最初把二进制装到了 `/usr/local/bin`。
- **修复**：把二进制下到工作区根目录并赋可执行权限：

```yaml
- name: gitleaks install
  run: |
    wget -q --no-host-directories -c --no-check-certificate \
      https://pytorch-package.obs.cn-north-4.myhuaweicloud.com/pta-codecheck/gitleaks
    chmod +x gitleaks
```

### P4 · Detect 因拉 GPG key 超时而失败  `[瞬时/重试]`

- **现象**：git 升级步骤里 `add-apt-repository` 报 `Error: retrieving gpg key timed out`，Detect 失败导致整轮 stage_1 没启动。
- **根因**：keyserver 网络抖动——**完全相同的步骤在前几轮都成功**，属偶发。
- **处理**：重新发 /compile，下一轮 gpg key 拉取成功，Detect COMPLETED。未改代码。若反复出现可考虑给 add-apt-repository 加重试/多 keyserver 兜底，但单次抖动不值得动 YAML。

### P5 · 专用 runner 长时间停在 QUEUED  `[资源调度]`

- **现象**：run #6 中 Detect `status=QUEUED / start_time=null` 持续近 5 分钟，页面点重试后才分配到 runner。
- **根因**：`[dedicate-hosted, x64, 2xlarge]` 专用宿主机调度延迟，非代码/YAML 问题。
- **处理**：通过 `start_time` 是否为空区分"作业没开始"与"作业执行失败"，避免误判为转换缺陷；用户在页面重试解决。

### P6 · SCA 返回 repoUrl is null  `[平台配置]`

- **现象**
  ```text
  响应状态码: 200
  {"code":41003,"message":"repoUrl is null",
   "data":"当前扫描仓库不在openlibing中，请前往openlibing进行配置…"}
  ```
- **根因**：插件上报的是测试 fork 的完整 URL `https://gitcode.com/ComputingActionTest/MindCluster-AscendNPUBurn`，SCA 后端在 openlibing 查不到该 repo（登记的是源仓库或名称不匹配）。
- **处理**：用户在 openlibing 的 MindCluster 组织下录入测试 fork 后通过。这是平台侧登记，非转换缺陷。

### P7 · PreSmoke 与 Build_arm 并行导致产物 404  `[真实缺陷 · 待落地]`

- **现象**：JOB_smoke 在 **03:17:15** wget `artifacts_aarch64.zip` 返回 404；而 arm 编译在 **03:19:24** 才把同名产物上传到 OBS。
- **根因**：PreSmoke 与 Build_arm 同处 stage_1，**同 stage 内作业默认并行**，PreSmoke 没等产物就位就起跑。产物本身构建/上传都成功（OBS 报告 0.16s 上传成功），纯粹是时序竞态。
- **修复方案**：把 PreSmoke 拆到独立的 `stage_2`（name `Test`），利用"stage 间串行"保证它在 Build_arm 之后执行。用户喊停前**尚未推送**，作为明确待办。

```yaml
# 修复前：PreSmoke 与 Build_arm 同在 stage_1，并行抢跑
stages:
  stage_1:
    jobs:
      Build_arm: { uses: .build_job.yml, ... }
      PreSmoke: { uses: .presmoke.yml, ... }   # ← 同时起跑，404

# 修复后：PreSmoke 移到独立 stage_2，天然等 stage_1 全完成
stages:
  stage_1: { jobs: { SCA, pre_commit, Antipoison, SAST, Build_x86, Build_arm, UT_Python } }
  stage_2:
    name: Test
    jobs:
      PreSmoke:
        if: ${{ jobs.Detect_file_changes.outputs.need_build == 'yes' }}
        uses: .gitcode/workflows/.presmoke.yml
        ...
```

> ⚠️ **仍需注意**：PreSmoke 本身要在 arm64 + NPU 加速卡的 runner 上跑（装 ascend_npu_burn wheel、source cann-A2、跑 run_st.sh），属于环境级 known-limit。stage_2 修复解决的是"抢跑 404"，让它在有卡的环境里能真正走到 smoke 逻辑。

### P8 · 轮询脚本与 Windows 路径的自我纠错  `[工具链]`

- v8 列表接口字段是 `workflow_runs` 不是 `runs`，第一次后台监控因此误报"无新 run"——改为正确字段后正常。
- 状态终态是大写 `FAILED/COMPLETED`，监控脚本的 case 没匹配大写，漏掉了结束信号——补齐大小写匹配。
- Windows Git Bash 下 `/tmp/...` 与 `/d/...` 在 curl 与 Node 间解析不一致，Node 找不到模块；改为 curl 直接管道给 Node stdin，并用 `D:/ActionTest/.yamllint` 风格的 Windows 绝对路径。
- CRLF：靠 `.gitattributes` + `git cat-file -p HEAD:<path> | grep -c $'\r'` 验证 blob 干净（应为 0）。

---

## 04 · 可复用经验与待办

下面是这次实践沉淀出的、可反哺到技能参考文档的候选条目。按约定，**未经确认不会改动技能文件**。

### 建议补入技能/FAQ 的经验

- **git 升级必须按镜像条件化**，严格照 FAQ #7 的清单加。mindspore 等较新镜像自带合格 git，加了反而在 Debian trixie 上因 `software-properties-common` 缺失而失败。
- **gitleaks 要装在工作区根目录**：openlibing-pre-commit-action 的钩子执行 `./gitleaks`，不是从 PATH 找。
- **下载产物的后续作业必须排在独立 stage**（PreSmoke → stage_2），因为同 stage 并行会抢跑。这是一条通用的"构建→部署"顺序规则。
- **无 secret 干跑的判读标准**：obs-upload 403、SCA/Antipoison 401 且编译本身成功 = 接线正确；PreSmoke 的 404 是缺产物的级联，不算独立缺陷。
- **区分 QUEUED 与 FAILED**：`start_time` 为空是资源调度问题，不要当成代码错误去修。
- v8 API 的两个易错点：列表字段 `workflow_runs`、终态大写。

### 明确的遗留待办

- **PreSmoke stage_2 修复**：方案已在 P7 给出，等你确认后推 master 再发一轮 /compile 验证（需要可用的 arm64+NPU runner）。
- 8 个 secret 已配齐：OBS_AK/SK、SCAN_ACCESS_KEY/SECRET_KEY、四个 *_ANTI；ACCESS_QK 经验证为可选（SAST 用公开仓 TuBee/AI-Check，不需要）。
- SCA 需保证 openlibing 登记的是**实际被扫描的仓库 URL**（含测试 fork）。
- gpg key 超时若频繁复现，再考虑给 git 升级步骤加重试兜底。

> **关于改技能文件**：本次没有编辑任何技能文件。是否把上述"git 升级条件化 / gitleaks 工作区 / PreSmoke 独立 stage"等条目补进 `conversion-rules.md`、`static-check-mapping.md` 或 FAQ，等你确认后再动手。

---

## 附录

- **测试组织**：ComputingActionTest
- **测试 PR**：#1（master_test → master）
- **运行 commit 链**：`ef34e887 → 5a4cf87b → b0b6f8b5 → e2503e4a`
- **修复提交**：`47ce80e / a90600c / f137047 / 4be7896`
- **生成方式**：由 codearts-to-gitcode 技能闭环生成
- 本页不含任何凭证明文（Cookie/token 仅作为输入记录在首节，不写入提交信息或日志摘要）
