
# syntax=docker/dockerfile:1

# 两个最终镜像使用同一个 Python 版本与 Debian 发行版。
ARG PYTHON_VERSION=3.13.15

# 构建时可指定默认时区，运行容器时仍可通过 TZ 环境变量覆盖。
ARG TZ=Asia/Shanghai


# ============================================================
# 依赖构建基础环境
# ============================================================

# 只负责安装 Python 依赖，不包含 StratForge 平台源码。
FROM python:${PYTHON_VERSION}-slim-trixie AS deps-base

# 只读取 dependency groups，不安装当前项目，因此不需要 VERSION。
COPY pyproject.toml /tmp/pyproject.toml

# 创建独立虚拟环境，使用支持 dependency groups 的 pip。
RUN python -m venv /opt/venv \
    && /opt/venv/bin/python -m pip install --no-cache-dir --upgrade 'pip>=25.1,<27'


# ============================================================
# 实盘依赖构建
# ============================================================

# 安装 live-image，包括基础引擎、Redis、PostgreSQL 和 TqSdk。
FROM deps-base AS live-deps

# 只允许预编译 wheel，避免不同架构意外进入源码编译。
# 不预编译字节码；验证依赖并记录实际安装版本。
# 最后移除虚拟环境中的 pip，减少复制到运行镜像的文件。
RUN /opt/venv/bin/python -m pip install --no-cache-dir --no-compile --only-binary=:all: \
    --group /tmp/pyproject.toml:live-image \
    && /opt/venv/bin/python -m pip check \
    && /opt/venv/bin/python -m pip freeze > /opt/venv/requirements.freeze.txt \
    && /opt/venv/bin/python -m pip uninstall -y pip


# ============================================================
# 研究依赖构建
# ============================================================

# 安装 research-image，包括数据分析、参数优化和 Web 服务依赖。
# 与实盘环境分别安装，避免不必要的依赖混入实盘镜像。
FROM deps-base AS research-deps

RUN /opt/venv/bin/python -m pip install --no-cache-dir --no-compile --only-binary=:all: \
    --group /tmp/pyproject.toml:research-image \
    && /opt/venv/bin/python -m pip check \
    && /opt/venv/bin/python -m pip freeze > /opt/venv/requirements.freeze.txt \
    && /opt/venv/bin/python -m pip uninstall -y pip


# ============================================================
# 公共运行环境
# ============================================================

# 运行镜像只包含 Python、系统运行库及必要的运行用户。
# 不继承构建环境，也不复制 pyproject.toml 或平台源码。
FROM python:${PYTHON_VERSION}-slim-trixie AS runtime

# 固定 UID/GID，方便宿主机持久化目录统一授权。
ARG APP_UID=10001
ARG APP_GID=10001

# 官方 Python slim-trixie 已包含 CA 证书和 tzdata，不再重复安装。
#
# /pythonlib/strategy_engine：平台源码只读挂载目录。
# /workdir：实盘状态、账户配置和本机锁。
# /research：研究快照、SQLite 索引、实验结果和日志。
#
# 数据目录由固定 UID/GID 持有。
# 宿主机 bind mount 后，仍以宿主机文件权限为准。
RUN set -eux; \
    groupadd --gid "${APP_GID}" app; \
    useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home \
    --shell /usr/sbin/nologin app; \
    install -d -o root -g root -m 0755 /pythonlib /pythonlib/strategy_engine; \
    install -d -o "${APP_UID}" -g "${APP_GID}" -m 0755 /workdir /research

# 优先使用虚拟环境中的 Python。
# /pythonlib 是外部挂载平台源码的模块搜索路径。
# 运行时不生成字节码，并关闭 Python 标准输出缓冲。
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONPATH="/pythonlib" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME="/home/app" \
    TZ="${TZ}"

# 两个生产镜像均以非 root 用户运行。
USER app:app


# ============================================================
# 实盘生产镜像
# ============================================================

FROM runtime AS live

# 只复制实盘依赖，不包含源码、账户配置和策略运行状态。
COPY --from=live-deps /opt/venv /opt/venv

# 持久化运行目录。
WORKDIR /workdir

# 声明需要外部挂载的目录：
# /pythonlib/strategy_engine：平台源码，建议只读挂载。
# /workdir：实盘配置和持久化状态，需要写入权限。
#
# VOLUME 只声明挂载点，不会自动绑定指定的宿主机目录。
VOLUME ["/pythonlib/strategy_engine", "/workdir"]

# 从挂载的平台源码启动策略引擎。
ENTRYPOINT ["python", "-m", "strategy_engine"]
CMD ["--help"]


# ============================================================
# 研究生产镜像
# ============================================================

FROM runtime AS research

# 只复制研究依赖，不包含平台源码或实盘配置。
COPY --from=research-deps /opt/venv /opt/venv

# 研究 Web 服务的预期监听端口。
# EXPOSE 只声明端口，不会自动启动服务或映射到宿主机。
# 实际启动 Web 服务时，需要使用相同端口并监听 0.0.0.0。
ARG RESEARCH_PORT=8765
ENV RESEARCH_PORT="${RESEARCH_PORT}"
EXPOSE ${RESEARCH_PORT}/tcp

# 研究数据与任务状态持久化目录。
WORKDIR /research

# 声明需要外部挂载的目录：
# /pythonlib/strategy_engine：平台源码，建议只读挂载。
# /research：快照、SQLite、实验结果和 worker 日志，需要写入权限。
VOLUME ["/pythonlib/strategy_engine", "/research"]

# 从挂载的平台源码启动研究 CLI。
ENTRYPOINT ["python", "-m", "strategy_engine.research.cli"]
CMD ["--help"]
