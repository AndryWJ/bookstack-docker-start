#!/bin/bash
# backup_bookstack.sh
# Розташування: /backups/backup.bash
# .env файл: у корені проекту

# ============================================
# Конфігурація
# ============================================

# Шлях до кореня проекту (де знаходиться .env файл)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

# Директорія для збереження бекапів (поряд з скриптом)
BACKUP_DIR="$(dirname "${BASH_SOURCE[0]}")/storage"

# Кількість днів для збереження бекапів
BACKUP_RETENTION_DAYS=30

# ============================================
# Функції
# ============================================

# Функція для отримання змінної з .env файлу
get_env_var() {
    local var_name="$1"
    if [ ! -f "$ENV_FILE" ]; then
        echo "ПОМИЛКА: Файл .env не знайдено: $ENV_FILE" >&2
        read -p "Press enter to continue"
exit 1
    fi
    grep -E "^${var_name}=" "$ENV_FILE" | cut -d '=' -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Функція для перевірки помилок
check_error() {
    if [ $? -ne 0 ]; then
        echo "ПОМИЛКА: $1" >&2
        read -p "Press enter to continue"
exit 1
    fi
}

# Функція для логування
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ============================================
# Головна частина скрипта
# ============================================

log_message "Запуск бекапу BookStack..."
log_message "PROJECT_ROOT: $PROJECT_ROOT"
log_message "ENV_FILE: $ENV_FILE"
log_message "BACKUP_DIR: $BACKUP_DIR"

# Створення директорії для бекапів
mkdir -p "$BACKUP_DIR"

# Отримання поточної дати для назви файлів
CURRENT_DATE=$(date '+%Y-%m-%d_%H-%M-%S')
CURRENT_DATE_ONLY=$(date '+%Y-%m-%d')

# Створення піддиректорії для поточної дати
DAILY_BACKUP_DIR="$BACKUP_DIR/$CURRENT_DATE_ONLY"
mkdir -p "$DAILY_BACKUP_DIR"

log_message "Бекапи будуть збережені в: $DAILY_BACKUP_DIR"

# ============================================
# Отримання змінних з .env
# ============================================

log_message "Читання конфігурації з $ENV_FILE..."

DB_USERNAME=$(get_env_var "DB_USERNAME")
DB_PASSWORD=$(get_env_var "DB_PASSWORD")
DB_DATABASE=$(get_env_var "DB_DATABASE")
BOOKSTACK_DB_CONTAINER_NAME=$(get_env_var "BOOKSTACK_DB_CONTAINER_NAME")
BOOKSTACK_CONTAINER_NAME=$(get_env_var "BOOKSTACK_CONTAINER_NAME")

# Перевірка отриманих змінних
if [ -z "$DB_USERNAME" ]; then
    echo "ПОМИЛКА: Змінна DB_USERNAME не знайдена в .env файлі" >&2
    read -p "Press enter to continue"
exit 1
fi
if [ -z "$DB_PASSWORD" ]; then
    echo "ПОМИЛКА: Змінна DB_PASSWORD не знайдена в .env файлі" >&2
    read -p "Press enter to continue"
exit 1
fi
if [ -z "$DB_DATABASE" ]; then
    echo "ПОМИЛКА: Змінна DB_DATABASE не знайдена в .env файлі" >&2
    read -p "Press enter to continue"
exit 1
fi
if [ -z "$BOOKSTACK_DB_CONTAINER_NAME" ]; then
    echo "ПОМИЛКА: Змінна BOOKSTACK_DB_CONTAINER_NAME не знайдена в .env файлі" >&2
    read -p "Press enter to continue"
exit 1
fi
if [ -z "$BOOKSTACK_CONTAINER_NAME" ]; then
    echo "ПОМИЛКА: Змінна BOOKSTACK_CONTAINER_NAME не знайдена в .env файлі" >&2
    read -p "Press enter to continue"
exit 1
fi

log_message "Отримано змінні:"
log_message "  DB_USERNAME: $DB_USERNAME"
log_message "  DB_DATABASE: $DB_DATABASE"
log_message "  DB_CONTAINER: $BOOKSTACK_DB_CONTAINER_NAME"
log_message "  APP_CONTAINER: $BOOKSTACK_CONTAINER_NAME"

# ============================================
# Бекап бази даних
# ============================================

DB_BACKUP_FILE="$DAILY_BACKUP_DIR/bookstack-db-$CURRENT_DATE.sql"
DB_BACKUP_COMPRESSED="$DAILY_BACKUP_DIR/bookstack-db-$CURRENT_DATE.sql.gz"

log_message "Створення бекапу бази даних..."

# Перевірка чи працює контейнер з БД
if ! docker ps --format '{{.Names}}' | grep -q "^${BOOKSTACK_DB_CONTAINER_NAME}$"; then
    log_message "ПОМИЛКА: Контейнер бази даних '$BOOKSTACK_DB_CONTAINER_NAME' не запущений"
    log_message "Запущені контейнери:"
    docker ps --format '{{.Names}}' | sed 's/^/  /'
    read -p "Press enter to continue"
exit 1
fi

# Створення бекапу бази даних
log_message "Виконуємо mysqldump..."
docker exec "$BOOKSTACK_DB_CONTAINER_NAME" mysqldump \
    -u "$DB_USERNAME" \
    -p"$DB_PASSWORD" \
    --single-transaction \
    --quick \
    --lock-tables=false \
    "$DB_DATABASE" > "$DB_BACKUP_FILE"

check_error "Не вдалося створити бекап бази даних"

# Перевірка розміру бекапу
BACKUP_SIZE=$(wc -c < "$DB_BACKUP_FILE" 2>/dev/null || echo "0")
if [ "$BACKUP_SIZE" -lt 1000 ]; then
    log_message "ПОМИЛКА: Бекап бази даних замалий ($BACKUP_SIZE байт)"
    log_message "Перші 10 рядків бекапу:"
    head -10 "$DB_BACKUP_FILE"
    rm -f "$DB_BACKUP_FILE"
    read -p "Press enter to continue"
exit 1
fi

log_message "Бекап БД створено успішно: $BACKUP_SIZE байт"

# Стиснення бекапу БД
log_message "Стиснення бекапу бази даних..."
gzip -f "$DB_BACKUP_FILE"
check_error "Не вдалося стиснути бекап БД"

DB_BACKUP_SIZE=$(ls -lh "$DB_BACKUP_COMPRESSED" | awk '{print $5}')
log_message "Бекап БД стиснуто: $DB_BACKUP_SIZE"

# ============================================
# Бекап файлів BookStack
# ============================================

FILES_BACKUP_FILE="$DAILY_BACKUP_DIR/bookstack-files-$CURRENT_DATE.tar.gz"

log_message "Створення бекапу файлів BookStack..."

# Перевірка чи працює контейнер BookStack
if ! docker ps --format '{{.Names}}' | grep -q "^${BOOKSTACK_CONTAINER_NAME}$"; then
    log_message "ПОМИЛКА: Контейнер BookStack '$BOOKSTACK_CONTAINER_NAME' не запущений"
    read -p "Press enter to continue"
exit 1
fi

# Створення бекапу файлів з /config директорії
log_message "Створення архіву файлів..."
# MSYS_NO_PATHCONV=1 docker exec $BOOKSTACK_CONTAINER_NAME tar -czf /tmp/bookstack-files-backup.tar.gz -C /config .
docker exec -it bookstack sh -c "tar -czf /tmp/bookstack-files-backup.tar.gz -C /config ."

check_error "Не вдалося створити архів файлів в контейнері"

# Копіювання архіву з контейнера
log_message "Копіювання архіву з контейнера..."
docker cp "$BOOKSTACK_CONTAINER_NAME:/tmp/bookstack-files-backup.tar.gz" "$FILES_BACKUP_FILE"

check_error "Не вдалося скопіювати архів з контейнера"

# Очищення тимчасового файлу в контейнері
MSYS_NO_PATHCONV=1 docker exec "$BOOKSTACK_CONTAINER_NAME" rm -f /tmp/bookstack-files-backup.tar.gz


# Перевірка розміру бекапу файлів
FILES_BACKUP_SIZE=$(ls -lh "$FILES_BACKUP_FILE" | awk '{print $5}')
log_message "Бекап файлів створено: $FILES_BACKUP_SIZE"

# ============================================
# Створення інформаційного файлу
# ============================================

INFO_FILE="$DAILY_BACKUP_DIR/backup-info.txt"

cat > "$INFO_FILE" << EOF
BookStack Backup Information
============================
Backup Date: $(date '+%Y-%m-%d %H:%M:%S')
Backup Directory: $DAILY_BACKUP_DIR

Database Information:
- Container: $BOOKSTACK_DB_CONTAINER_NAME
- Database: $DB_DATABASE
- User: $DB_USERNAME
- Backup File: $(basename "$DB_BACKUP_COMPRESSED")
- Size: $DB_BACKUP_SIZE

Files Information:
- Container: $BOOKSTACK_CONTAINER_NAME
- Directory: /config
- Backup File: $(basename "$FILES_BACKUP_FILE")
- Size: $FILES_BACKUP_SIZE

Environment Variables (from $ENV_FILE):
- DB_USERNAME: $DB_USERNAME
- DB_DATABASE: $DB_DATABASE
- DB_CONTAINER: $BOOKSTACK_DB_CONTAINER_NAME
- APP_CONTAINER: $BOOKSTACK_CONTAINER_NAME

Created by: $0
EOF

log_message "Інформаційний файл створено: $INFO_FILE"

# ============================================
# Очищення старих бекапів
# ============================================

log_message "Очищення бекапів старіших ніж $BACKUP_RETENTION_DAYS днів..."

# Знаходимо та видаляємо старі директорії з бекапами
find "$BACKUP_DIR" -type d -name "20*" -mtime +$BACKUP_RETENTION_DAYS 2>/dev/null | while read -r old_dir; do
    log_message "Видалення старого бекапу: $(basename "$old_dir")"
    rm -rf "$old_dir"
done

# ============================================
# Фінальний звіт
# ============================================

TOTAL_SIZE=$(du -sh "$DAILY_BACKUP_DIR" | cut -f1)

log_message "========================================="
log_message "БЕКАП УСПІШНО ЗАВЕРШЕНО!"
log_message "========================================="
log_message "Директорія з бекапами: $DAILY_BACKUP_DIR"
log_message "Файли бекапу:"
log_message "  1. $(basename "$DB_BACKUP_COMPRESSED") - $DB_BACKUP_SIZE"
log_message "  2. $(basename "$FILES_BACKUP_FILE") - $FILES_BACKUP_SIZE"
log_message "  3. backup-info.txt"
log_message "Загальний розмір: $TOTAL_SIZE"
log_message "========================================="

# Список всіх бекапів
log_message "Наявні бекапи:"
ls -la "$BACKUP_DIR" | grep -E '^d.*20[0-9]{2}-' | awk '{print "  " $9 " (" $6 " " $7 ")"}'

read -p "Press enter to continue"
exit 0