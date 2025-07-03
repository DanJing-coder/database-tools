#!/bin/bash

# 数据库配置
DB_HOST="dwh-dbr16-lp2"
DB_USER="jing_d"
DB_PASSWORD="dwukiRP2MBMn"
DB_PORT="9030"

# 默认配置
DEFAULT_SQL_FILE="query.sql"
DEFAULT_OUTPUT_FILE="output.csv"

# 显示帮助信息
function show_help() {
    echo "用法: $0 [选项] [SQL文件路径]"
    echo "执行SQL文件并将结果输出到CSV文件"
    echo ""
    echo "选项:"
    echo "  -h, --help            显示此帮助信息"
    echo "  -o, --output FILE     指定输出CSV文件路径 (默认: $DEFAULT_OUTPUT_FILE)"
    echo "  -d, --database NAME   指定要使用的数据库"
    echo "  -H, --no-header       不输出列名（默认输出）"
    echo ""
    echo "如果未指定SQL文件路径，默认使用: $DEFAULT_SQL_FILE"
    exit 0
}

# 初始化变量
SQL_FILE=""
OUTPUT_FILE="$DEFAULT_OUTPUT_FILE"
DATABASE=""
SKIP_HEADER="false"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -d|--database)
            DATABASE="$2"
            shift 2
            ;;
        -H|--no-header)
            SKIP_HEADER="true"
            shift
            ;;
        *)
            # 第一个非选项参数视为SQL文件路径
            if [[ -z "$SQL_FILE" ]]; then
                SQL_FILE="$1"
                shift
            else
                echo "错误: 不支持的参数 '$1'" >&2
                show_help
            fi
            ;;
    esac
done

if [[ -z "$SQL_FILE" ]]; then
    SQL_FILE="$DEFAULT_SQL_FILE"
    if [[ ! -f "$SQL_FILE" && -n "$0" ]]; then
        SCRIPT_DIR=$(dirname "$(realpath -s "$0")")
        SQL_FILE="$SCRIPT_DIR/$DEFAULT_SQL_FILE"
    fi
fi

SQL_FILE=$(realpath -s "$SQL_FILE")
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")

if [[ ! -f "$SQL_FILE" ]]; then
    echo "错误：SQL文件 '$SQL_FILE' 不存在！" >&2
    exit 1
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "错误：输出目录 '$OUTPUT_DIR' 不存在！" >&2
    exit 1
fi

if [[ ! -w "$OUTPUT_DIR" ]]; then
    echo "错误：没有写入权限到 '$OUTPUT_DIR'！" >&2
    exit 1
fi

# 构建MySQL命令 - 直接在命令行中传递密码
MYSQL_CMD="mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD -P $DB_PORT"

if [[ -n "$DATABASE" ]]; then
    MYSQL_CMD="$MYSQL_CMD -D $DATABASE"
fi

# 根据选项决定是否跳过列名
if [[ "$SKIP_HEADER" == "true" ]]; then
    MYSQL_CMD="$MYSQL_CMD --batch --raw  --skip-column-names --execute"
else
    # 确保默认输出列名
    MYSQL_CMD="$MYSQL_CMD --batch --raw  --execute"
fi

SQL_COMMAND="source $SQL_FILE"

echo "正在执行SQL文件: $SQL_FILE"
echo "输出文件: $OUTPUT_FILE"

# 执行SQL并捕获错误，同时忽略密码警告
temp_output=$(mktemp)
temp_error=$(mktemp)

# 执行命令并捕获输出和错误
if $MYSQL_CMD "$SQL_COMMAND" > "$temp_output" 2> "$temp_error"; then
    # 命令成功执行
    cp "$temp_output" "$OUTPUT_FILE"
    echo "SQL执行完成,结果已输出到 $OUTPUT_FILE"
    
    line_count=$(wc -l < "$OUTPUT_FILE")
    echo "输出行数: $line_count"
else
    # 命令执行失败，检查错误是否只是密码警告
    has_real_error=$(grep -v "Using a password on the command line interface can be insecure" "$temp_error")
    
    if [[ -n "$has_real_error" ]]; then
        # 存在真实错误，显示错误信息
        echo "SQL执行失败!错误信息:" >&2
        grep -v "Using a password on the command line interface can be insecure" "$temp_error" >&2
        exit 1
    else
        # 只有密码警告，命令实际上成功执行
        cp "$temp_output" "$OUTPUT_FILE"
        echo "SQL执行完成,结果已输出到 $OUTPUT_FILE"
        
        line_count=$(wc -l < "$OUTPUT_FILE")
        echo "输出行数: $line_count"
    fi
fi

# 清理临时文件
rm -f "$temp_output" "$temp_error"