#!/bin/bash
# restore_bookstack.sh - ВЕРСІЯ ДЛЯ WINDOWS/GIT BASH

# ============================================
# Конфігурація
# ============================================

# Шлях до кореня проекту
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

# Директорія з бекапами
BACKUP_DIR="$(dirname "${BASH_SOURCE[0]}")/storage"

# ============================================
# Функції
# ============================================

get_env_var() {
    local var_name="$1"
    if [ ! -f "$ENV_FILE" ]; then
        echo "ПОМИЛКА: Файл .env не знайдено: $ENV_FILE" >&2
        read -p "Press enter to continue"
        exit 1
    fi
    grep -E "^${var_name}=" "$ENV_FILE" | cut -d '=' -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

check_error() {
    if [ $? -ne 0 ]; then
        echo "ПОМИЛКА: $1" >&2
        read -p "Press enter to continue"
        exit 1
    fi
}

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Функція для конвертації шляху Windows -> Linux (для Docker)
convert_path_to_linux() {
    local windows_path="$1"
    # Конвертуємо D:\path\to\file -> //d/path/to/file
    echo "$windows_path" | sed -e 's/\\/\//g' -e 's/^\([A-Za-z]\):/\/\/\L\1/' -e 's/\/\//\//'
}

# Функція для вибору бекапу
select_backup() {
    local backup_dirs=()
    local i=1
    
    echo "Доступні бекапи:"
    echo "================"
    
    # Знаходимо всі директорії з бекапами
    for dir in "$BACKUP_DIR"/*; do
        if [ -d "$dir" ] && [[ "$(basename "$dir")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            backup_dirs+=("$dir")
            
            # Перевіряємо наявність файлів бекапу
            db_file=$(find "$dir" -name "bookstack-db-*.sql.gz" -o -name "bookstack-db-*.sql" | head -1)
            files_file=$(find "$dir" -name "bookstack-files-*.tar.gz" -o -name "bookstack-files-*.tar" | head -1)
            
            backup_date=$(basename "$dir")
            backup_size=$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "0B")
            
            echo "  $i) $backup_date"
            echo "     Розмір: $backup_size"
            
            if [ -n "$db_file" ]; then
                db_size=$(ls -lh "$db_file" 2>/dev/null | awk '{print $5}' || echo "N/A")
                echo "     База даних: ✓ ($db_size)"
            else
                echo "     База даних: ✗"
            fi
            
            if [ -n "$files_file" ]; then
                files_size=$(ls -lh "$files_file" 2>/dev/null | awk '{print $5}' || echo "N/A")
                echo "     Файли: ✓ ($files_size)"
            else
                echo "     Файли: ✗"
            fi
            
            echo ""
            i=$((i + 1))
        fi
    done
    
    if [ ${#backup_dirs[@]} -eq 0 ]; then
        echo "ПОМИЛКА: Не знайдено жодного бекапу в $BACKUP_DIR" >&2
        read -p "Press enter to continue"
        exit 1
    fi
    
    read -rp "Виберіть номер бекапу для відновлення (1-${#backup_dirs[@]}): " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backup_dirs[@]} ]; then
        echo "Невірний вибір" >&2
        read -p "Press enter to continue"
        exit 1
    fi
    
    SELECTED_BACKUP_DIR="${backup_dirs[$((choice - 1))]}"
    echo ""
}

# ============================================
# Головна частина скрипта
# ============================================

clear
echo "========================================"
echo "    ВІДНОВЛЕННЯ BOOKSTACK (Windows)"
echo "========================================"
echo ""

log_message "Запуск відновлення BookStack..."

# Перевірка наявності директорії з бекапами
if [ ! -d "$BACKUP_DIR" ]; then
    log_message "ПОМИЛКА: Директорія з бекапами не існує: $BACKUP_DIR"
    read -p "Press enter to continue"
    exit 1
fi

# Отримання змінних з .env
log_message "Читання конфігурації з $ENV_FILE..."

DB_USERNAME=$(get_env_var "DB_USERNAME")
DB_PASSWORD=$(get_env_var "DB_PASSWORD")
DB_DATABASE=$(get_env_var "DB_DATABASE")
BOOKSTACK_DB_CONTAINER_NAME=$(get_env_var "BOOKSTACK_DB_CONTAINER_NAME")
BOOKSTACK_CONTAINER_NAME=$(get_env_var "BOOKSTACK_CONTAINER_NAME")

log_message "Отримано змінні:"
log_message "  DB_USERNAME: $DB_USERNAME"
log_message "  DB_DATABASE: $DB_DATABASE"
log_message "  DB_CONTAINER: $BOOKSTACK_DB_CONTAINER_NAME"
log_message "  APP_CONTAINER: $BOOKSTACK_CONTAINER_NAME"

# Вибір бекапу
select_backup
log_message "Обраний бекап: $SELECTED_BACKUP_DIR"

# Пошук файлів бекапу
DB_BACKUP=$(find "$SELECTED_BACKUP_DIR" -name "bookstack-db-*.sql.gz" | head -1)
if [ -z "$DB_BACKUP" ]; then
    DB_BACKUP=$(find "$SELECTED_BACKUP_DIR" -name "bookstack-db-*.sql" | head -1)
fi

FILES_BACKUP=$(find "$SELECTED_BACKUP_DIR" -name "bookstack-files-*.tar.gz" | head -1)
if [ -z "$FILES_BACKUP" ]; then
    FILES_BACKUP=$(find "$SELECTED_BACKUP_DIR" -name "bookstack-files-*.tar" | head -1)
fi

echo "Знайдено файли бекапу:"
if [ -n "$DB_BACKUP" ]; then
    echo "  ✅ База даних: $(basename "$DB_BACKUP")"
else
    echo "  ❌ База даних: не знайдено"
fi

if [ -n "$FILES_BACKUP" ]; then
    echo "  ✅ Файли: $(basename "$FILES_BACKUP")"
else
    echo "  ❌ Файли: не знайдено"
fi

echo ""

# Вибір опцій відновлення
echo "Що відновлювати?"
echo "  1) Тільки базу даних"
echo "  2) Тільки файли"
echo "  3) Все (базу даних та файли)"
echo ""

while true; do
    read -rp "Виберіть опцію (1-3): " restore_option
    case $restore_option in
        1)
            RESTORE_DB=true
            RESTORE_FILES=false
            break
            ;;
        2)
            RESTORE_DB=false
            RESTORE_FILES=true
            break
            ;;
        3)
            RESTORE_DB=true
            RESTORE_FILES=true
            break
            ;;
        *)
            echo "Невірний вибір. Спробуйте ще раз."
            ;;
    esac
done

echo ""

# Підтвердження
echo "========================================"
echo "     ПІДТВЕРДЖЕННЯ ВІДНОВЛЕННЯ"
echo "========================================"
echo "Бекап: $(basename "$SELECTED_BACKUP_DIR")"
echo ""

if [ "$RESTORE_DB" = true ] && [ -n "$DB_BACKUP" ]; then
    echo "✅ ВІДНОВЛЕННЯ БАЗИ ДАНИХ:"
    echo "   Контейнер: $BOOKSTACK_DB_CONTAINER_NAME"
    echo "   База: $DB_DATABASE"
    echo "   Файл: $(basename "$DB_BACKUP")"
    echo ""
fi

if [ "$RESTORE_FILES" = true ] && [ -n "$FILES_BACKUP" ]; then
    echo "✅ ВІДНОВЛЕННЯ ФАЙЛІВ:"
    echo "   Контейнер: $BOOKSTACK_CONTAINER_NAME"
    echo "   Директорія: /config"
    echo "   Файл: $(basename "$FILES_BACKUP")"
    echo ""
fi

echo "❗ УВАГА: Ця операція ПЕРЕЗАПИШЕ поточні дані!"
echo ""

read -rp "Ви впевнені, що хочете продовжити? (так/ні): " confirmation

if [[ ! "$confirmation" =~ ^(так|yes|y|д|да|так так)$ ]]; then
    log_message "Відновлення скасовано користувачем"
    read -p "Press enter to continue"
    exit 0
fi

echo ""

# ============================================
# Створення бекапу поточного стану
# ============================================

log_message "Створення бекапу поточного стану перед відновленням..."

PRE_RESTORE_DIR="$BACKUP_DIR/pre-restore-$(date '+%Y-%m-%d_%H-%M-%S')"
mkdir -p "$PRE_RESTORE_DIR"

# Бекап поточної бази даних
if docker ps --format '{{.Names}}' | grep -q "^${BOOKSTACK_DB_CONTAINER_NAME}$"; then
    log_message "Створення бекапу поточної бази даних..."
    docker exec "$BOOKSTACK_DB_CONTAINER_NAME" mysqldump \
        -u "$DB_USERNAME" \
        -p"$DB_PASSWORD" \
        --single-transaction \
        "$DB_DATABASE" > "$PRE_RESTORE_DIR/pre-restore-db.sql" 2>/dev/null
    
    if [ -s "$PRE_RESTORE_DIR/pre-restore-db.sql" ]; then
        gzip "$PRE_RESTORE_DIR/pre-restore-db.sql"
        log_message "Бекап поточної БД збережено: $PRE_RESTORE_DIR/pre-restore-db.sql.gz"
    else
        rm -f "$PRE_RESTORE_DIR/pre-restore-db.sql"
        log_message "Не вдалося створити бекап поточної БД"
    fi
fi

# ============================================
# ВІДНОВЛЕННЯ БАЗИ ДАНИХ (ВИПРАВЛЕНА ВЕРСІЯ)
# ============================================

if [ "$RESTORE_DB" = true ] && [ -n "$DB_BACKUP" ]; then
    log_message "Відновлення бази даних..."
    
    # Перевірка контейнера
    if ! docker ps --format '{{.Names}}' | grep -q "^${BOOKSTACK_DB_CONTAINER_NAME}$"; then
        log_message "ПОМИЛКА: Контейнер БД '$BOOKSTACK_DB_CONTAINER_NAME' не запущений"
        read -p "Press enter to continue"
        exit 1
    fi
    
    # Зупиняємо BookStack для безпечного відновлення БД
    log_message "Зупинка контейнера BookStack..."
    docker stop "$BOOKSTACK_CONTAINER_NAME" 2>/dev/null || true
    
    # ✅ ВАЖЛИВО: Створюємо тимчасовий файл SQL
    TEMP_SQL_FILE="/tmp/restore_db_$(date +%s).sql"
    
    if [[ "$DB_BACKUP" == *.gz ]]; then
        log_message "Розпакування стисненого бекапу БД..."
        gunzip -c "$DB_BACKUP" > "$TEMP_SQL_FILE"
    else
        log_message "Копіювання бекапу БД..."
        cp "$DB_BACKUP" "$TEMP_SQL_FILE"
    fi
    
    # Перевірка файлу
    if [ ! -s "$TEMP_SQL_FILE" ]; then
        log_message "ПОМИЛКА: Файл для відновлення БД порожній"
        rm -f "$TEMP_SQL_FILE"
        docker start "$BOOKSTACK_CONTAINER_NAME" 2>/dev/null || true
        read -p "Press enter to continue"
        exit 1
    fi
    
    # ✅ ВАЖЛИВО: Копіюємо файл SQL в контейнер БД
    log_message "Копіювання SQL файлу в контейнер БД..."
    docker cp "$TEMP_SQL_FILE" "$BOOKSTACK_DB_CONTAINER_NAME:/tmp/restore_db.sql"
    check_error "Не вдалося скопіювати файл БД в контейнер"
    
    # Видаляємо поточну базу даних та створюємо нову
    log_message "Видалення поточної бази даних..."
    docker exec "$BOOKSTACK_DB_CONTAINER_NAME" mysql \
        -u "$DB_USERNAME" \
        -p"$DB_PASSWORD" \
        -e "DROP DATABASE IF EXISTS \`$DB_DATABASE\`; CREATE DATABASE \`$DB_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
    
    # ✅ ВАЖЛИВО: Відновлення бази даних з файлу В КОНТЕЙНЕРІ
    log_message "Відновлення бази даних з бекапу..."
    
    # Спосіб 1: Безпосередньо з файлу в контейнері
    docker exec "$BOOKSTACK_DB_CONTAINER_NAME" sh -c "
        mysql -u '$DB_USERNAME' -p'$DB_PASSWORD' '$DB_DATABASE' < /tmp/restore_db.sql
    "
    
    RESULT=$?
    
    if [ $RESULT -eq 0 ]; then
        log_message "✅ Базу даних успішно відновлено"
    else
        log_message "❌ Не вдалося відновити базу даних (код помилки: $RESULT)"
        
        # Альтернативний спосіб: через пайп
        log_message "Спроба альтернативного методу відновлення..."
        gunzip -c "$DB_BACKUP" 2>/dev/null | \
            docker exec -i "$BOOKSTACK_DB_CONTAINER_NAME" mysql \
                -u "$DB_USERNAME" \
                -p"$DB_PASSWORD" \
                "$DB_DATABASE"
        
        if [ $? -eq 0 ]; then
            log_message "✅ Базу даних відновлено альтернативним методом"
        else
            log_message "❌ Обидва методи не вдалися"
        fi
    fi
    
    # Очищення тимчасових файлів
    log_message "Очищення тимчасових файлів..."
    rm -f "$TEMP_SQL_FILE"
    docker exec "$BOOKSTACK_DB_CONTAINER_NAME" rm -f /tmp/restore_db.sql 2>/dev/null
    
    # Запускаємо BookStack
    log_message "Запуск контейнера BookStack..."
    docker start "$BOOKSTACK_CONTAINER_NAME" 2>/dev/null || true
    
    # Чекаємо на запуск
    log_message "Очікування запуску BookStack (10 секунд)..."
    sleep 10
fi

# ============================================
# ВІДНОВЛЕННЯ ФАЙЛІВ (ВИПРАВЛЕНА ВЕРСІЯ)
# ============================================

if [ "$RESTORE_FILES" = true ] && [ -n "$FILES_BACKUP" ]; then
    log_message "Відновлення файлів BookStack..."
    
    # Перевірка контейнера
    if ! docker ps --format '{{.Names}}' | grep -q "^${BOOKSTACK_CONTAINER_NAME}$"; then
        log_message "ПОМИЛКА: Контейнер BookStack '$BOOKSTACK_CONTAINER_NAME' не запущений"
        read -p "Press enter to continue"
        exit 1
    fi
    
    # Створюємо бекап поточних файлів
    log_message "Створення бекапу поточних файлів..."
    docker exec "$BOOKSTACK_CONTAINER_NAME" tar -czf /tmp/current_files_backup.tar.gz -C /config . 2>/dev/null || true
    
    # ✅ ВАЖЛИВО: Копіюємо архів для відновлення в контейнер
    log_message "Копіювання архіву файлів в контейнер..."
    
    # Використовуємо MSYS_NO_PATHCONV для правильного шляху в Windows
    export MSYS_NO_PATHCONV=1
    docker cp "$FILES_BACKUP" "$BOOKSTACK_CONTAINER_NAME:/tmp/restore_files.tar.gz"
    unset MSYS_NO_PATHCONV
    
    if [ $? -ne 0 ]; then
        log_message "ПОМИЛКА: Не вдалося скопіювати архів файлів в контейнер"
        read -p "Press enter to continue"
        exit 1
    fi
    
    # Відновлення файлів
    log_message "Відновлення файлів з архіву..."
    
    # ✅ Виконуємо відновлення крок за кроком з детальним логуванням
    docker exec "$BOOKSTACK_CONTAINER_NAME" sh -c "
        echo 'Крок 1: Перевірка архіву...'
        if [ ! -f /tmp/restore_files.tar.gz ]; then
            echo 'ПОМИЛКА: Архів не знайдено'
            exit 1
        fi
        
        echo 'Крок 2: Очищення директорії /config...'
        # Зберігаємо приховані файли та конфігурацію
        find /config -maxdepth 1 -type f ! -name '.*' -exec rm -f {} \; 2>/dev/null || true
        find /config -maxdepth 1 -type d ! -name '.' ! -name '.*' -exec rm -rf {} \; 2>/dev/null || true
        
        echo 'Крок 3: Розпакування бекапу...'
        tar -xzf /tmp/restore_files.tar.gz -C /config
        
        if [ \$? -eq 0 ]; then
            echo 'Крок 4: Виправлення прав доступу...'
            chown -R abc:abc /config 2>/dev/null || true
            chmod -R 755 /config 2>/dev/null || true
            echo '✅ Відновлення файлів завершено успішно'
            exit 0
        else
            echo '❌ Помилка при розпакуванні'
            exit 1
        fi
    "
    
    RESTORE_RESULT=$?
    
    if [ $RESTORE_RESULT -eq 0 ]; then
        log_message "✅ Файли успішно відновлено"
    else
        log_message "❌ Помилка при відновленні файлів"
        
        # Спроба відновлення початкового стану
        log_message "Спроба відновити початковий стан файлів..."
        docker exec "$BOOKSTACK_CONTAINER_NAME" tar -xzf /tmp/current_files_backup.tar.gz -C /config 2>/dev/null || true
    fi
    
    # Очищення тимчасових файлів
    log_message "Очищення тимчасових файлів..."
    docker exec "$BOOKSTACK_CONTAINER_NAME" rm -f /tmp/restore_files.tar.gz /tmp/current_files_backup.tar.gz 2>/dev/null
fi

# ============================================
# Перезапуск контейнерів
# ============================================

log_message "Перезапуск контейнерів для застосування змін..."

# Перезапускаємо BookStack
if docker ps --format '{{.Names}}' | grep -q "^${BOOKSTACK_CONTAINER_NAME}$"; then
    log_message "Перезапуск контейнера BookStack..."
    docker restart "$BOOKSTACK_CONTAINER_NAME" 2>/dev/null || true
fi

# Перезапускаємо БД (якщо відновлювали)
if [ "$RESTORE_DB" = true ] && docker ps --format '{{.Names}}' | grep -q "^${BOOKSTACK_DB_CONTAINER_NAME}$"; then
    log_message "Перезапуск контейнера бази даних..."
    docker restart "$BOOKSTACK_DB_CONTAINER_NAME" 2>/dev/null || true
fi

# Чекаємо на запуск
log_message "Очікування повного запуску (15 секунд)..."
sleep 15

# ============================================
# Перевірка результату
# ============================================

echo ""
echo "========================================"
echo "     РЕЗУЛЬТАТ ВІДНОВЛЕННЯ"
echo "========================================"
echo ""

# Перевірка стану контейнерів
echo "Статус контейнерів:"
echo "-------------------"

BOOKSTACK_STATUS=$(docker ps --filter "name=$BOOKSTACK_CONTAINER_NAME" --format "{{.Status}}" 2>/dev/null || echo "не запущено")
DB_STATUS=$(docker ps --filter "name=$BOOKSTACK_DB_CONTAINER_NAME" --format "{{.Status}}" 2>/dev/null || echo "не запущено")

if [ "$BOOKSTACK_STATUS" != "не запущено" ]; then
    echo "✅ BookStack: запущено ($BOOKSTACK_STATUS)"
else
    echo "❌ BookStack: не запущено"
fi

if [ "$DB_STATUS" != "не запущено" ]; then
    echo "✅ База даних: запущено ($DB_STATUS)"
else
    echo "❌ База даних: не запущено"
fi

echo ""

# Інформація про відновлення
echo "Відновлені дані:"
echo "----------------"

if [ "$RESTORE_DB" = true ] && [ -n "$DB_BACKUP" ]; then
    echo "✅ База даних: ВІДНОВЛЕНО"
    echo "   Файл: $(basename "$DB_BACKUP")"
    echo "   Розмір: $(ls -lh "$DB_BACKUP" 2>/dev/null | awk '{print $5}' || echo "невідомо")"
else
    echo "❌ База даних: НЕ ВІДНОВЛЕНО"
fi

if [ "$RESTORE_FILES" = true ] && [ -n "$FILES_BACKUP" ]; then
    echo "✅ Файли: ВІДНОВЛЕНО"
    echo "   Файл: $(basename "$FILES_BACKUP")"
    echo "   Розмір: $(ls -lh "$FILES_BACKUP" 2>/dev/null | awk '{print $5}' || echo "невідомо")"
else
    echo "❌ Файли: НЕ ВІДНОВЛЕНО"
fi

echo ""

# Важлива інформація
echo "Важлива інформація:"
echo "-------------------"
echo "📁 Бекап початкового стану збережено в:"
echo "   $PRE_RESTORE_DIR"
echo ""
echo "🔗 BookStack доступний за адресою:"
BOOKSTACK_DOMAIN=$(get_env_var "BOOKSTACK_DOMAIN" 2>/dev/null || echo "ваш-домен")
echo "   http://$BOOKSTACK_DOMAIN"
echo ""
echo "👤 Облікові дані для входу:"
echo "   Email/пароль з бекапу"
echo ""
echo "🔄 Якщо виникли проблеми:"
echo "   1. Перевірте логи контейнерів:"
echo "      docker logs $BOOKSTACK_CONTAINER_NAME"
echo "      docker logs $BOOKSTACK_DB_CONTAINER_NAME"
echo "   2. Відновіть початковий стан з: $PRE_RESTORE_DIR"
echo ""

echo "========================================"
log_message "Відновлення завершено!"

read -p "Натисніть Enter для завершення..."
exit 0