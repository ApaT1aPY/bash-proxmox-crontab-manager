#!/bin/bash

# Цвета для оформления
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
DEFAULT='\033[0m'

# Файл системного crontab
CRON_FILE="/etc/crontab"
BACKUP_DIR="/etc/cron.backups"

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ошибка: Скрипт должен запускаться от root.${DEFAULT}"
    echo -e "${YELLOW}Используйте: sudo $0${DEFAULT}"
    exit 1
fi

# Проверка наличия команд Proxmox
if ! command -v pct &>/dev/null || ! command -v qm &>/dev/null; then
    echo -e "${RED}Ошибка: Команды pct или qm не найдены. Убедитесь, что скрипт запускается на хосте Proxmox.${DEFAULT}"
    exit 1
fi


# Функции пользовательского интерфейса

# Главное меню
show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════╗${DEFAULT}"
    echo -e "${BLUE}║${GREEN}        Proxmox Cron Manager        ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}╠════════════════════════════════════╣${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 1) Просмотр задач Proxmox          ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 2) Добавить задачу Proxmox         ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 3) Редактировать задачу Proxmox    ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 4) Удалить задачу Proxmox          ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 5) Статус cron сервиса             ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 0) Выход                           ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}╚════════════════════════════════════╝${DEFAULT}"
}

# Пауза до нажатия Enter
pause() {
    echo -e "${YELLOW}Нажмите Enter для продолжения...${DEFAULT}" >&2
    read -r
}

# Подтверждение действия
confirm_action() {
    local action=$1
    local item=$2
    echo -en "${YELLOW}Вы хотите $action $item? (y/n): ${DEFAULT}" >&2
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Действие отменено${DEFAULT}" >&2
        return 1
    fi
    return 0
}


# Функции резервного копирования

# Создаёт резервную копию /etc/crontab в папке BACKUP_DIR с меткой времени
create_backup() {
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    local backup_file="$BACKUP_DIR/crontab.backup.$(date +%Y%m%d_%H%M%S)"
    if cp "$CRON_FILE" "$backup_file" 2>/dev/null; then
        echo -e "${GREEN}Создан backup: $backup_file${DEFAULT}" >&2
        BACKUP_FILE="$backup_file"
        return 0
    else
        echo -e "${RED}Ошибка: Не удалось создать backup${DEFAULT}" >&2
        return 1
    fi
}

# Восстанавливает файл crontab из последнего созданного бэкапа
restore_backup() {
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        echo -e "${YELLOW}Попытка восстановления из бэкапа $BACKUP_FILE${DEFAULT}" >&2
        if cp "$BACKUP_FILE" "$CRON_FILE"; then
            echo -e "${GREEN}Восстановление выполнено${DEFAULT}" >&2
            return 0
        else
            echo -e "${RED}Критическая ошибка: не удалось восстановить бэкап!${DEFAULT}" >&2
            return 1
        fi
    fi
    return 1
}

# Перезагружает сервис cron
reload_cron() {
    echo -e "${YELLOW}Перезагрузка cron сервиса...${DEFAULT}" >&2
    if systemctl list-units --full -all | grep -Fq 'cron.service'; then
        systemctl try-reload-or-restart cron
    elif systemctl list-units --full -all | grep -Fq 'crond.service'; then
        systemctl try-reload-or-restart crond
    else
        echo -e "${RED}Не удалось найти сервис cron. Изменения вступят после перезагрузки.${DEFAULT}" >&2
    fi
}

# Безопасно записывает изменения в /etc/crontab:
# - создаёт бэкап
# - перемещает временный файл на место оригинального
# - в случае ошибки восстанавливает из бэкапа
# Параметры: $1 - оригинальный файл, $2 - временный файл с новым содержимым
safe_write() {
    local orig_file=$1
    local temp_file=$2
    local backup_success=false

    if create_backup; then
        backup_success=true
    else
        echo -e "${RED}Не удалось создать бэкап, операция прервана${DEFAULT}" >&2
        return 1
    fi

    if mv "$temp_file" "$orig_file" 2>/dev/null; then
        echo -e "${GREEN}✓ Изменения сохранены${DEFAULT}" >&2
        reload_cron
        return 0
    else
        echo -e "${RED}Ошибка при записи в $orig_file${DEFAULT}" >&2
        if $backup_success; then
            restore_backup
        fi
        return 1
    fi
}


# Функции валидации cron-задач

# Проверяет существование пользователя
user_exists() {
    id "$1" &>/dev/null
}

# Проверяет одно временное поле на корректность формата и диапазона
check_time_field() {
    local field=$1
    local name=$2
    local min=$3
    local max=$4

    [ "$field" = "*" ] && return 0

    IFS=',' read -ra parts <<< "$field"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)/([0-9]+)$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            local step=${BASH_REMATCH[3]}
            if [ "$start" -lt "$min" ] || [ "$end" -gt "$max" ] || [ "$step" -le 0 ]; then
                echo -e "${RED}Ошибка: Неверный диапазон с шагом '$part' в поле '$name'${DEFAULT}" >&2
                return 1
            fi
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            if [ "$start" -lt "$min" ] || [ "$end" -gt "$max" ] || [ "$start" -gt "$end" ]; then
                echo -e "${RED}Ошибка: Неверный диапазон '$part' в поле '$name'${DEFAULT}" >&2
                return 1
            fi
        elif [[ "$part" =~ ^\*/([0-9]+)$ ]]; then
            local step=${BASH_REMATCH[1]}
            if [ "$step" -le 0 ]; then
                echo -e "${RED}Ошибка: Неверный шаг '$part' в поле '$name'${DEFAULT}" >&2
                return 1
            fi
        elif [[ "$part" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            local val=${BASH_REMATCH[1]}
            local step=${BASH_REMATCH[2]}
            if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ] || [ "$step" -le 0 ]; then
                echo -e "${RED}Ошибка: Неверное значение/шаг '$part' в поле '$name'${DEFAULT}" >&2
                return 1
            fi
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [ "$part" -lt "$min" ] || [ "$part" -gt "$max" ]; then
                echo -e "${RED}Ошибка: Значение $part в поле '$name' должно быть в диапазоне $min-$max${DEFAULT}" >&2
                return 1
            fi
        else
            echo -e "${RED}Ошибка: Некорректный формат '$part' в поле '$name'${DEFAULT}" >&2
            return 1
        fi
    done
    return 0
}

# Основная функция проверки синтаксиса целой строки cron
check_syntax() {
    local task=$1

    if [ -z "$task" ]; then
        echo -e "${RED}Ошибка: Задача не может быть пустой${DEFAULT}" >&2
        return 1
    fi

    # Обработка специальных меток
    if [[ "$task" =~ ^@[a-zA-Z]+\ +([^ ]+)\ +(.+)$ ]]; then
        local special="${BASH_REMATCH[0]%% *}"
        local user="${BASH_REMATCH[1]}"
        local command="${BASH_REMATCH[2]}"
        case "$special" in
            @reboot|@yearly|@annually|@monthly|@weekly|@daily|@hourly)
                if [ -z "$user" ]; then
                    echo -e "${RED}Ошибка: В специальной задаче не указан пользователь${DEFAULT}" >&2
                    return 1
                fi
                if ! user_exists "$user"; then
                    echo -e "${RED}Ошибка: Пользователь '$user' не существует${DEFAULT}" >&2
                    return 1
                fi
                if [ -z "$command" ]; then
                    echo -e "${RED}Ошибка: Не указана команда${DEFAULT}" >&2
                    return 1
                fi
                echo -e "${GREEN}✓ Корректный специальный синтаксис: $special${DEFAULT}" >&2
                return 0
                ;;
            *)
                echo -e "${RED}Ошибка: Неизвестный специальный параметр '$special'${DEFAULT}" >&2
                echo -e "${YELLOW}Допустимые: @reboot, @yearly, @annually, @monthly, @weekly, @daily, @hourly${DEFAULT}" >&2
                return 1
                ;;
        esac
    fi

    local fields=$(echo "$task" | awk '{print NF}')
    if [ "$fields" -lt 6 ]; then
        echo -e "${RED}Ошибка: Недостаточно полей в задаче (минимум 6: минуты часы дни месяцы дни_недели пользователь команда)${DEFAULT}" >&2
        return 1
    fi

    local minute=$(echo "$task" | awk '{print $1}')
    local hour=$(echo "$task" | awk '{print $2}')
    local day=$(echo "$task" | awk '{print $3}')
    local month=$(echo "$task" | awk '{print $4}')
    local weekday=$(echo "$task" | awk '{print $5}')
    local user=$(echo "$task" | awk '{print $6}')
    local command=$(echo "$task" | cut -d' ' -f7-)

    if ! user_exists "$user"; then
        echo -e "${RED}Ошибка: Пользователь '$user' не существует${DEFAULT}" >&2
        return 1
    fi

    if [ -z "$command" ]; then
        echo -e "${RED}Ошибка: Не указана команда${DEFAULT}" >&2
        return 1
    fi

    check_time_field "$minute" "минуты" 0 59 || return 1
    check_time_field "$hour" "часы" 0 23 || return 1
    check_time_field "$day" "дни" 1 31 || return 1
    check_time_field "$month" "месяцы" 1 12 || return 1
    check_time_field "$weekday" "дни_недели" 0 7 || return 1

    echo -e "${GREEN}✓ Синтаксис корректный${DEFAULT}" >&2
    return 0
}


# Функции для работы с Proxmox

# Получает список контейнеров
get_containers() {
    pct list | awk 'NR>1 {print $1 " " $2}' 2>/dev/null
}

# Получает список виртуальных машин
get_vms() {
    qm list | awk 'NR>1 {print $1 " " $2}' 2>/dev/null
}

# Интерактивно выбирает контейнер, возвращает ID в stdout, сообщения в stderr
select_container() {
    local containers=()
    while IFS= read -r line; do
        containers+=("$line")
    done < <(get_containers)

    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${RED}Нет доступных контейнеров.${DEFAULT}" >&2
        return 1
    fi

    echo -e "${CYAN}Доступные контейнеры:${DEFAULT}" >&2
    for i in "${!containers[@]}"; do
        echo "$((i+1))) ${containers[$i]}" >&2
    done

    local choice
    read -r -e -p "Выберите номер контейнера: " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then
        echo -e "${RED}Неверный выбор.${DEFAULT}" >&2
        return 1
    fi

    local selected="${containers[$((choice-1))]}"
    echo "$selected" | awk '{print $1}' # возвращаем только ID в stdout
    return 0
}

# Интерактивно выбирает виртуальную машину, возвращает ID в stdout, сообщения в stderr
select_vm() {
    local vms=()
    while IFS= read -r line; do
        vms+=("$line")
    done < <(get_vms)

    if [ ${#vms[@]} -eq 0 ]; then
        echo -e "${RED}Нет доступных виртуальных машин.${DEFAULT}" >&2
        return 1
    fi

    echo -e "${CYAN}Доступные виртуальные машины:${DEFAULT}" >&2
    for i in "${!vms[@]}"; do
        echo "$((i+1))) ${vms[$i]}" >&2
    done

    local choice
    read -r -e -p "Выберите номер VM: " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#vms[@]} ]; then
        echo -e "${RED}Неверный выбор.${DEFAULT}" >&2
        return 1
    fi

    local selected="${vms[$((choice-1))]}"
    echo "$selected" | awk '{print $1}'
    return 0
}

# Выбирает действие для указанного типа и ID, возвращает команду в stdout, сообщения в stderr
select_action() {
    local type=$1 # "container" или "vm"
    local id=$2
    echo -e "${CYAN}Выберите действие:${DEFAULT}" >&2
    echo "1) Запустить" >&2
    echo "2) Мягко выключить (shutdown)" >&2
    echo "3) Немедленно выключить (stop)" >&2
    echo "4) Перезагрузить (reboot)" >&2
    echo "5) Приостановить (suspend)" >&2
    echo "6) Возобновить (resume)" >&2
    read -r -e -p "Ваш выбор (1-6): " action_choice

    if [ -z "$action_choice" ]; then
        echo -e "${YELLOW}Действие отменено${DEFAULT}" >&2
        return 1
    fi

    case $action_choice in
        1) 
            if [ "$type" = "container" ]; then
                echo "pct start $id"
            else
                echo "qm start $id"
            fi
            ;;
        2)
            if [ "$type" = "container" ]; then
                echo "pct shutdown $id"
            else
                echo "qm shutdown $id"
            fi
            ;;
        3)
            if [ "$type" = "container" ]; then
                echo "pct stop $id"
            else
                echo "qm stop $id"
            fi
            ;;
        4)
            if [ "$type" = "container" ]; then
                echo "pct reboot $id"
            else
                echo "qm reboot $id"
            fi
            ;;
        5)  # Приостановить
            if [ "$type" = "container" ]; then
                echo "pct suspend $id"
            else
                echo "qm suspend $id"
            fi
            ;;
        6)  # Возобновить
            if [ "$type" = "container" ]; then
                echo "pct resume $id"
            else
                echo "qm resume $id"
            fi
            ;;
        *)
            echo -e "${RED}Неверный выбор.${DEFAULT}" >&2
            return 1
            ;;
    esac
    return 0
}

# Формирует полную строку задачи cron из расписания и команды
generate_cron_line() {
    local schedule=$1
    local command=$2
    echo "$schedule root $command"
}

# Получает массив задач Proxmox (содержат pct или qm) из crontab
get_proxmox_tasks() {
    tasks=()
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]] && [[ "$line" =~ pct|qm ]]; then
            tasks+=("$line")
        fi
    done < "$CRON_FILE"
}

# Показывает информацию о формате cron-задач
show_task_format_info() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${DEFAULT}" >&2
    echo -e "${GREEN}ФОРМАТ ЗАДАЧИ CRON:${DEFAULT}" >&2
    echo -e "${YELLOW}минуты часы дни месяцы дни_недели${DEFAULT}" >&2
    echo >&2
    echo -e "${GREEN}СПЕЦИАЛЬНЫЕ ЗНАЧЕНИЯ:${DEFAULT}" >&2
    echo -e "  ${PURPLE}@reboot${DEFAULT}    - при каждом запуске системы" >&2
    echo -e "  ${PURPLE}@yearly${DEFAULT}    - 0 0 1 1 * (раз в год)" >&2
    echo -e "  ${PURPLE}@annually${DEFAULT}  - 0 0 1 1 * (раз в год)" >&2
    echo -e "  ${PURPLE}@monthly${DEFAULT}   - 0 0 1 * * (раз в месяц)" >&2
    echo -e "  ${PURPLE}@weekly${DEFAULT}    - 0 0 * * 0 (раз в неделю)" >&2
    echo -e "  ${PURPLE}@daily${DEFAULT}     - 0 0 * * * (каждый день)" >&2
    echo -e "  ${PURPLE}@hourly${DEFAULT}    - 0 * * * * (каждый час)" >&2
    echo >&2
    echo -e "${GREEN}СИМВОЛЫ:${DEFAULT}" >&2
    echo -e "  ${YELLOW}*${DEFAULT} - любое значение" >&2
    echo -e "  ${YELLOW},${DEFAULT} - список значений (1,2,3)" >&2
    echo -e "  ${YELLOW}-${DEFAULT} - диапазон значений (1-5)" >&2
    echo -e "  ${YELLOW}/${DEFAULT} - шаг значений (*/5 = каждые 5)" >&2
    echo >&2
    echo -e "${GREEN}ПРИМЕРЫ:${DEFAULT}" >&2
    echo -e "  ${CYAN}*/5 * * * *${DEFAULT}     - каждые 5 минут" >&2
    echo -e "  ${CYAN}0 2 * * *${DEFAULT}       - каждый день в 2:00" >&2
    echo -e "  ${CYAN}0 0 * * 0${DEFAULT}       - каждое воскресенье" >&2
    echo -e "  ${CYAN}@daily${DEFAULT}           - каждый день" >&2
    echo -e "  ${CYAN}@reboot${DEFAULT}        - при загрузке" >&2
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${DEFAULT}" >&2
}

# Добавляет новую задачу Proxmox
add_task() {
    echo -e "${GREEN}Добавление новой задачи Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2

    # Выбор типа (VM или контейнер)
    echo -e "${CYAN}Выберите тип:${DEFAULT}" >&2
    echo "1) Виртуальная машина (VM)" >&2
    echo "2) Контейнер (LXC)" >&2
    read -r -e -p "Ваш выбор (1-2): " type_choice

    local type=""
    local id=""
    case $type_choice in
        1)
            type="vm"
            id=$(select_vm)
            if [ $? -ne 0 ] || [ -z "$id" ]; then
                pause
                return 1
            fi
            ;;
        2)
            type="container"
            id=$(select_container)
            if [ $? -ne 0 ] || [ -z "$id" ]; then
                pause
                return 1
            fi
            ;;
        *)
            echo -e "${RED}Неверный выбор.${DEFAULT}" >&2
            pause
            return 1
            ;;
    esac

    # Выбор действия
    local command=$(select_action "$type" "$id")
    if [ $? -ne 0 ] || [ -z "$command" ]; then
        pause
        return 1
    fi

    # Показываем информацию о формате cron
    show_task_format_info

    # Напоминание о выбранном объекте
    local type_display=""
    if [ "$type" = "vm" ]; then
        type_display="Виртуальная машина"
    else
        type_display="Контейнер"
    fi
    echo -e "${YELLOW}Выбрано: ${type_display} №${id}${DEFAULT}" >&2
    echo >&2

    # Ввод расписания
    echo -e "${CYAN}Введите cron-расписание (5 полей, например: 0 2 * * * или @daily):${DEFAULT}" >&2
    read -r -e -p "Расписание: " schedule
    if [ -z "$schedule" ]; then
        echo -e "${YELLOW}Добавление отменено${DEFAULT}" >&2
        pause
        return 0
    fi

    # Формируем полную строку задачи
    local full_task=$(generate_cron_line "$schedule" "$command")

    # Проверка синтаксиса
    if ! check_syntax "$full_task"; then
        pause
        return 1
    fi

    if confirm_action "добавить задачу" "\"$full_task\""; then
        local temp_file
        temp_file=$(mktemp) || { echo -e "${RED}Ошибка создания временного файла${DEFAULT}" >&2; pause; return 1; }
        trap 'rm -f "$temp_file"' EXIT

        cp "$CRON_FILE" "$temp_file" 2>/dev/null || true
        echo "$full_task" >> "$temp_file"

        if safe_write "$CRON_FILE" "$temp_file"; then
            : 
        else
            echo -e "${RED}Не удалось добавить задачу${DEFAULT}" >&2
        fi
        rm -f "$temp_file"
        trap - EXIT
    fi

    pause
}

# Редактирует задачу Proxmox (только расписание)
edit_task() {
    if [ ! -f "$CRON_FILE" ]; then
        echo -e "${RED}Файл $CRON_FILE не найден${DEFAULT}" >&2
        pause
        return 1
    fi

    echo -e "${GREEN}Редактирование задачи Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2

    tasks=()
    get_proxmox_tasks

    if [ ${#tasks[@]} -eq 0 ]; then
        echo -e "${RED}Нет задач Proxmox для редактирования${DEFAULT}" >&2
        pause
        return 1
    fi

    for i in "${!tasks[@]}"; do
        echo "$((i+1))) ${tasks[$i]}" >&2
    done
    echo "-----------------------------------" >&2

    read -r -e -p "Введите номер задачи для редактирования (Enter - отмена): " task_num

    if [ -z "$task_num" ]; then
        echo -e "${YELLOW}Редактирование отменено${DEFAULT}" >&2
        pause
        return 0
    fi

    if ! [[ "$task_num" =~ ^[0-9]+$ ]] || [ "$task_num" -lt 1 ] || [ "$task_num" -gt ${#tasks[@]} ]; then
        echo -e "${RED}Неверный номер задачи${DEFAULT}" >&2
        pause
        return 1
    fi

    local idx=$((task_num-1))
    local old_task="${tasks[$idx]}"
    echo -e "${YELLOW}Текущая задача:${DEFAULT} $old_task" >&2

    local old_command=$(echo "$old_task" | cut -d' ' -f7-)
    local old_user=$(echo "$old_task" | awk '{print $6}')

    echo -e "${CYAN}Введите новое cron-расписание (5 полей или специальная метка):${DEFAULT}" >&2
    read -r -e -p "Новое расписание (Enter - отмена): " new_schedule

    if [ -z "$new_schedule" ]; then
        echo -e "${YELLOW}Редактирование отменено${DEFAULT}" >&2
        pause
        return 0
    fi

    local new_task="$new_schedule $old_user $old_command"

    if ! check_syntax "$new_task"; then
        pause
        return 1
    fi

    if confirm_action "заменить задачу" "\"$old_task\" на \"$new_task\""; then
        local temp_file
        temp_file=$(mktemp) || { echo -e "${RED}Ошибка создания временного файла${DEFAULT}" >&2; pause; return 1; }
        trap 'rm -f "$temp_file"' EXIT

        local count=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
                echo "$line" >> "$temp_file"
            else
                if [[ "$line" =~ pct|qm ]]; then
                    if [ $count -eq $idx ]; then
                        echo "$new_task" >> "$temp_file"
                    else
                        echo "$line" >> "$temp_file"
                    fi
                    ((count++))
                else
                    echo "$line" >> "$temp_file"
                fi
            fi
        done < "$CRON_FILE"

        if safe_write "$CRON_FILE" "$temp_file"; then
            : 
        else
            echo -e "${RED}Не удалось отредактировать задачу${DEFAULT}" >&2
        fi
        rm -f "$temp_file"
        trap - EXIT
    fi

    pause
}

# Удаляет задачу Proxmox
delete_task() {
    if [ ! -f "$CRON_FILE" ]; then
        echo -e "${RED}Файл $CRON_FILE не найден${DEFAULT}" >&2
        pause
        return 1
    fi

    echo -e "${GREEN}Удаление задачи Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2

    tasks=()
    get_proxmox_tasks

    if [ ${#tasks[@]} -eq 0 ]; then
        echo -e "${RED}Нет задач Proxmox для удаления${DEFAULT}" >&2
        pause
        return 1
    fi

    for i in "${!tasks[@]}"; do
        echo "$((i+1))) ${tasks[$i]}" >&2
    done
    echo "-----------------------------------" >&2

    read -r -e -p "Введите номер задачи для удаления (Enter - отмена): " task_num

    if [ -z "$task_num" ]; then
        echo -e "${YELLOW}Удаление отменено${DEFAULT}" >&2
        pause
        return 0
    fi

    if ! [[ "$task_num" =~ ^[0-9]+$ ]] || [ "$task_num" -lt 1 ] || [ "$task_num" -gt ${#tasks[@]} ]; then
        echo -e "${RED}Неверный номер задачи${DEFAULT}" >&2
        pause
        return 1
    fi

    local idx=$((task_num-1))
    local task_to_delete="${tasks[$idx]}"
    echo -e "${YELLOW}Задача для удаления:${DEFAULT} $task_to_delete" >&2

    if confirm_action "удалить задачу" "\"$task_to_delete\""; then
        local temp_file
        temp_file=$(mktemp) || { echo -e "${RED}Ошибка создания временного файла${DEFAULT}" >&2; pause; return 1; }
        trap 'rm -f "$temp_file"' EXIT

        local count=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
                echo "$line" >> "$temp_file"
            else
                if [[ "$line" =~ pct|qm ]]; then
                    if [ $count -ne $idx ]; then
                        echo "$line" >> "$temp_file"
                    fi
                    ((count++))
                else
                    echo "$line" >> "$temp_file"
                fi
            fi
        done < "$CRON_FILE"

        if safe_write "$CRON_FILE" "$temp_file"; then
            :
        else
            echo -e "${RED}Не удалось удалить задачу${DEFAULT}" >&2
        fi
        rm -f "$temp_file"
        trap - EXIT
    fi

    pause
}

# Просматривает задачи Proxmox
view_tasks() {
    if [ ! -f "$CRON_FILE" ]; then
        echo -e "${RED}Файл $CRON_FILE не найден${DEFAULT}" >&2
        pause
        return 1
    fi

    echo -e "${GREEN}Задачи Proxmox в cron:${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    local count=0
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]] && [[ "$line" =~ pct|qm ]]; then
            count=$((count+1))
            echo "$count) $line" >&2
        fi
    done < "$CRON_FILE"

    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}Нет активных задач Proxmox${DEFAULT}" >&2
    fi
    echo "-----------------------------------" >&2
    pause
}

# Проверяет статус cron сервиса
check_cron_status() {
    echo -e "${GREEN}Статус cron сервиса:${DEFAULT}" >&2
    echo "-----------------------------------" >&2

    local service_name=""
    if systemctl list-units --full -all | grep -Fq 'cron.service'; then
        service_name="cron"
    elif systemctl list-units --full -all | grep -Fq 'crond.service'; then
        service_name="crond"
    fi

    if [ -n "$service_name" ]; then
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            echo -e "Статус: ${GREEN}Активен${DEFAULT} ✓" >&2
        else
            echo -e "Статус: ${RED}Не активен${DEFAULT} ✗" >&2
        fi

        if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
            echo -e "Автозапуск: ${GREEN}Включен${DEFAULT}" >&2
        else
            echo -e "Автозапуск: ${RED}Отключен${DEFAULT}" >&2
        fi

        echo "-----------------------------------" >&2
        systemctl status "$service_name" --no-pager -l
    else
        echo -e "${RED}Сервис cron не найден${DEFAULT}" >&2
    fi
    echo "-----------------------------------" >&2
    pause
}


# Убеждается, что файл crontab существует, и создаёт его при необходимости
ensure_cron_file() {
    if [ ! -f "$CRON_FILE" ]; then
        echo -e "${YELLOW}Файл $CRON_FILE не найден, создаём...${DEFAULT}" >&2
        cat > "$CRON_FILE" <<EOF
# /etc/crontab: system-wide crontab
# Unlike any other crontab you don't have to run the 'crontab'
# command to install the new version when you edit this file
# and files in /etc/cron.d. These files also have username fields,
# that none of the other crontabs do.

SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Example of job definition:
# .---------------- minute (0 - 59)
# |  .------------- hour (0 - 23)
# |  |  .---------- day of month (1 - 31)
# |  |  |  .------- month (1 - 12) OR jan,feb,mar,apr ...
# |  |  |  |  .---- day of week (0 - 6) (Sunday=0 or 7) OR sun,mon,tue,wed,thu,fri,sat
# |  |  |  |  |
# *  *  *  *  * user-name command to be executed
EOF
        echo -e "${GREEN}Файл создан.${DEFAULT}" >&2
    fi
}

ensure_cron_file


# Основной цикл программы
while true; do
    show_menu
    read -r -e -p "Выберите пункт меню: " choice

    choice=$(echo "$choice" | tr -d '\r' | xargs)

    case $choice in
        1)
            view_tasks
            ;;
        2)
            add_task
            ;;
        3)
            edit_task
            ;;
        4)
            delete_task
            ;;
        5)
            check_cron_status
            ;;
        0)
            echo -e "${GREEN}До свидания!${DEFAULT}" >&2
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор. Пожалуйста, выберите 0-5${DEFAULT}" >&2
            pause
            ;;
    esac
done
