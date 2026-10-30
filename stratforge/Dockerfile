
# syntax=docker/dockerfile:1

# 两个最终镜像使用同一 Python 版本和 Debian 发行版
ARG PYTHON_VERSION=3.13.15

# 构建和运行时均可指定时区
ARG TZ=Asia/Shanghai

# 依赖构建环境
FROM python:${PYTHON_VERSION}-slim-trixie AS deps-base

# 仅安装依赖组，无需复制平台源码或版本文件
COPY pyproject.toml /tmp/pyproject.toml

# 创建虚拟环境，使用支持依赖组的 pip
RUN python -m venv /opt/venv \
    && /opt/venv/bin/python -m pip install --no-cache-dir --upgrade 'pip>=25.1,<27'

# 实盘依赖，包括基础引擎、Redis、PostgreSQL 和 TqSdk
FROM deps-base AS live-deps

# 仅使用预编译包，检查依赖并记录版本，最后移除 pip
RUN /opt/venv/bin/python -m pip install --no-cache-dir --no-compile --only-binary=:all: \
        --group /tmp/pyproject.toml:live-image \
    && /opt/venv/bin/python -m pip check \
    && /opt/venv/bin/python -m pip freeze > /opt/venv/requirements.freeze.txt \
    && /opt/venv/bin/python -m pip uninstall -y pip

# 研究依赖，包括数据分析、参数优化和 Web 服务依赖
FROM deps-base AS research-deps

RUN /opt/venv/bin/python -m pip install --no-cache-dir --no-compile --only-binary=:all: \
        --group /tmp/pyproject.toml:research-image \
    && /opt/venv/bin/python -m pip check \
    && /opt/venv/bin/python -m pip freeze > /opt/venv/requirements.freeze.txt \
    && /opt/venv/bin/python -m pip uninstall -y pip

# 公共运行环境，仅包含 Python 和系统运行库
FROM python:${PYTHON_VERSION}-slim-trixie AS runtime

ARG TZ

# 非 root 用户默认 UID/GID 为 1000:1000
ARG APP_UID=1000
ARG APP_GID=1000

# 基础镜像已包含 CA 证书和时区数据，仅创建用户及挂载目录
RUN set -eux; \
    python -m pip uninstall -y pip; \
    rm -rf /root/.cache; \
    groupadd --gid "${APP_GID}" app; \
    useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home \
        --shell /usr/sbin/nologin app; \
    install -d -o root -g root -m 0755 /pythonlib /pythonlib/strategy_engine; \
    install -d -o "${APP_UID}" -g "${APP_GID}" -m 0755 /workdir /research

# 使用虚拟环境和外部挂载源码，关闭字节码写入与标准输出缓冲
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONPATH="/pythonlib" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME="/home/app" \
    TZ="${TZ}"

USER app:app

# 实盘运行镜像
FROM runtime AS live

# 仅复制实盘依赖
COPY --from=live-deps /opt/venv /opt/venv

WORKDIR /workdir

# 源码建议只读挂载，实盘配置和状态目录需允许运行用户写入
VOLUME ["/pythonlib/strategy_engine", "/workdir"]

ENTRYPOINT ["python", "-m", "strategy_engine"]

CMD ["--help"]

# 研究运行镜像
FROM runtime AS research

# 仅复制研究依赖
COPY --from=research-deps /opt/venv /opt/venv

# 启动研究 Web 服务时需监听 0.0.0.0 和此端口
ARG RESEARCH_PORT=8765
ENV RESEARCH_PORT="${RESEARCH_PORT}"
EXPOSE ${RESEARCH_PORT}/tcp

WORKDIR /research

# 源码建议只读挂载，研究数据和任务状态目录需允许运行用户写入
VOLUME ["/pythonlib/strategy_engine", "/research"]

ENTRYPOINT ["python", "-m", "strategy_engine.research.cli"]

CMD ["--help"]
