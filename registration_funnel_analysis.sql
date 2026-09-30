/* Задание 1:
Показать в динамике по месяцам 
1) количество успешных регистраций 
2) среднее время
При расчете среднего времени нужно исключать выбросы, в рамках задачи будем считать за
выбросы регистрации, которые длятся более 30 минут
*/

-- Проверяем, встречаются ли повторные Sign In внутри одного case_id.
SELECT COUNT(*) AS more_sign_in
FROM (SELECT case_id
    FROM events
    WHERE event_name = 'Sign In'
    GROUP BY case_id
	HAVING COUNT(*) > 1) t
/* 3374 случая с несколькими Sign In, старт регистрации будем считать 
как последний Sign In перед этапом main (Персональный данные)

registration_cases_final:
Находим первое успешное завершение.
Для каждого Sign In знаем следующий Sign In.
Внутри этого промежутка ищем первое экранное событие.
Если это main, считаем такой Sign In началом попытки.
Если таких попыток несколько — берём последнюю.
*/

DROP TABLE IF EXISTS registration_cases_final;

CREATE TABLE registration_cases_final AS
WITH finishes AS (
    SELECT case_id, MIN(event_ts) AS finish_reg
    FROM events
    WHERE event_category = 'result'
      AND event_name = 'Submit > Response'
    GROUP BY case_id
),
sign_ins AS (
    SELECT e.case_id, e.event_ts AS sign_in_ts, f.finish_reg,
           LEAD(e.event_ts) OVER (
               PARTITION BY e.case_id ORDER BY e.event_ts
           ) AS next_sign_in_ts
    FROM events e
    JOIN finishes f ON f.case_id = e.case_id
                   AND e.event_ts <= f.finish_reg
    WHERE e.event_category = 'session'
      AND e.event_name = 'Sign In'
),
first_screen_time AS (
    SELECT s.case_id, s.sign_in_ts,
           MIN(e.event_ts) AS first_screen_ts
    FROM sign_ins s
    JOIN events e ON e.case_id = s.case_id
                 AND e.event_ts > s.sign_in_ts
                 AND e.event_ts <= s.finish_reg
                 AND (s.next_sign_in_ts IS NULL
                      OR e.event_ts < s.next_sign_in_ts)
                 AND e.event_category NOT IN ('session', 'result')
    GROUP BY s.case_id, s.sign_in_ts
),
starts AS (
    SELECT fs.case_id, MAX(fs.sign_in_ts) AS start_reg
    FROM first_screen_time fs
    WHERE EXISTS (
        SELECT 1
        FROM events e
        WHERE e.case_id = fs.case_id
          AND e.event_ts = fs.first_screen_ts
          AND e.event_category = 'main')
    GROUP BY fs.case_id
)
SELECT f.case_id, s.start_reg, f.finish_reg,
       f.finish_reg - s.start_reg AS total_reg
FROM finishes f
LEFT JOIN starts s ON f.case_id = s.case_id
	

SELECT
    COUNT(*) AS successful_cases,
    COUNT(*) FILTER (WHERE start_reg IS NULL) AS no_start,
    COUNT(*) FILTER (WHERE total_reg < interval '0 minutes') AS wrong_time,
    COUNT(*) FILTER (WHERE total_reg > interval '30 minutes') AS over_30_min
FROM registration_cases_final;

-- Из 126 154 успешных кейсов 2 кейса не содержат полного начала клиентского пути, 242 выброса 

SELECT DATE_TRUNC('month', finish_reg)::date AS month,
       COUNT(*) AS successful_registrations,
       ROUND(AVG(EXTRACT(EPOCH FROM total_reg) / 60) FILTER (
           WHERE total_reg <= interval '30 minutes'), 2) AS avg_min
FROM registration_cases_final
GROUP BY 1
ORDER BY 1;

/* Задание 2:
Единица анализа: успешный case_id с корректным стартом и длительностью 0..30 минут.
Повторные посещения формы суммируются. Дополнительные формы входят в основную.
Правило границы: от START до первого экранного события время относится
к первому экрану; после обычного экранного события время до следующего
относится к текущему экрану; после успешного Submit > Response время
до следующего экранного события относится к следующему экрану.
Последний промежуток перед FINISH относится к последнему экрану.
Это операционное допущение: точный момент показа экрана в данных не логируется.
*/

-- найдем опциональные формы
SELECT DISTINCT event_category
FROM events
WHERE event_category NOT IN ('main', 'identification', 'taxResidentInfo',
            'addresses', 'employment', 'contacts', 'servicePackage',
            'cards', 'accessCard', 'summary', 'questionnaire', 'docsUpload')
ORDER BY event_category;

-- cardsDelivery относится к cards (заказ именных карт)
-- confirm = summary (Проверка данных и подписание черновика)
-- nonResidentInfo = taxResidentInfo (Налоговое резидентсво)

DROP TABLE IF EXISTS registration_steps_final;

CREATE TABLE registration_steps_final AS
WITH valid_cases AS (
    SELECT case_id, start_reg, finish_reg, total_reg
    FROM registration_cases_final
    WHERE total_reg BETWEEN INTERVAL '0 seconds' AND INTERVAL '30 minutes'
),
screen_events AS (
    SELECT e.case_id, e.event_ts, e.event_name,
           CASE e.event_category
               WHEN 'nonResidentInfo' THEN 'taxResidentInfo'
               WHEN 'cardsDelivery' THEN 'cards'
               WHEN 'confirm' THEN 'summary'
               ELSE e.event_category
           END AS main_step
    FROM events e
    JOIN valid_cases v ON v.case_id = e.case_id
                      AND e.event_ts BETWEEN v.start_reg AND v.finish_reg
    WHERE e.event_category IN (
        'main', 'identification', 'taxResidentInfo', 'nonResidentInfo',
        'addresses', 'employment', 'contacts', 'servicePackage',
        'cards', 'cardsDelivery', 'accessCard', 'summary', 'confirm',
        'questionnaire', 'docsUpload'
    )
),
timeline AS (
    SELECT case_id, start_reg AS event_ts, NULL::text AS event_name,
           NULL::text AS main_step, 0 AS event_rank
    FROM valid_cases
    UNION ALL
    SELECT case_id, event_ts, event_name, main_step, 1 AS event_rank
    FROM screen_events
    UNION ALL
    SELECT case_id, finish_reg AS event_ts, NULL::text AS event_name,
           NULL::text AS main_step, 2 AS event_rank
    FROM valid_cases
),
ordered AS (
    SELECT *,
           LEAD(event_ts) OVER w AS next_ts,
           LEAD(main_step) OVER w AS next_step
    FROM timeline
    WINDOW w AS (
        PARTITION BY case_id
        ORDER BY event_ts, event_rank, main_step, event_name
    )
),
intervals AS (
    SELECT case_id,
           CASE
               WHEN event_rank = 0 THEN next_step
               WHEN event_name = 'Submit > Response' AND next_step IS NOT NULL
                   THEN next_step
               ELSE main_step
           END AS main_step,
           next_ts - event_ts AS event_duration
    FROM ordered
    WHERE next_ts IS NOT NULL
)
SELECT case_id, main_step, SUM(event_duration) AS step_time
FROM intervals
WHERE main_step IS NOT NULL
GROUP BY case_id, main_step;


-- Проверка наличия расхождений
SELECT COUNT(*) AS cases_with_difference
FROM (
    SELECT r.case_id,
        r.total_reg - SUM(s.step_time) AS diff
    FROM registration_cases_final r
    JOIN registration_steps_final s ON r.case_id = s.case_id
    WHERE r.start_reg IS NOT NULL AND r.total_reg <= interval '30 minutes'
    GROUP BY r.case_id, r.total_reg) t
WHERE diff != interval '0 seconds';
-- сумма времени по экранным формам полностью совпадает с общим временем регистрации

-- проверка 12 шагов
SELECT DISTINCT main_step
FROM registration_steps_final
ORDER BY main_step;

-- Контроль средних по месяцам; разница должна быть 0 до округления.
WITH valid_cases AS (
    SELECT case_id, DATE_TRUNC('month', finish_reg)::date AS month,
           EXTRACT(EPOCH FROM total_reg) AS total_seconds
    FROM registration_cases_final
    WHERE total_reg BETWEEN INTERVAL '0 seconds' AND INTERVAL '30 minutes'
), step_totals AS (
    SELECT v.month, v.case_id, v.total_seconds,
           COALESCE(SUM(EXTRACT(EPOCH FROM s.step_time)), 0) AS step_seconds
    FROM valid_cases v
    LEFT JOIN registration_steps_final s USING (case_id)
    GROUP BY v.month, v.case_id, v.total_seconds
)
SELECT month, COUNT(*) AS cases_in_average,
       ROUND(AVG(total_seconds)::numeric, 2) AS avg_total_seconds,
       ROUND(AVG(step_seconds)::numeric, 2) AS sum_avg_steps_seconds,
       ROUND(AVG(total_seconds - step_seconds)::numeric, 6) AS difference
FROM step_totals
GROUP BY month
ORDER BY month;


-- Среднее время каждого из 12 этапов, секунды на один успешный кейс.
-- Непройденный этап получает 0, чтобы сумма средних равнялась общему среднему.
WITH step_dim(step_order, main_step, step_name) AS (
    VALUES
    (1, 'main', 'Персональные данные'),
    (2, 'identification', 'Идентификация паспортных данных'),
    (3, 'taxResidentInfo', 'Резидент или информация о нерезиденте'),
    (4, 'addresses', 'Адреса'),
    (5, 'employment', 'Занятость'),
    (6, 'contacts', 'Контактная информация'),
    (7, 'servicePackage', 'ПУ и счета'),
    (8, 'cards', 'Заказ именных карт'),
    (9, 'accessCard', 'Моментальная выдача карты'),
    (10, 'summary', 'Проверка данных и подписание черновика'),
    (11, 'questionnaire', 'Подписание анкеты'),
    (12, 'docsUpload', 'Прикрепление документов')
),
valid_cases AS (
    SELECT case_id, DATE_TRUNC('month', finish_reg)::date AS month
    FROM registration_cases_final
    WHERE total_reg BETWEEN INTERVAL '0 seconds' AND INTERVAL '30 minutes'
)
SELECT v.month, d.step_order, d.main_step, d.step_name,
       COUNT(*) AS cases_in_average,
       ROUND(AVG(COALESCE(EXTRACT(EPOCH FROM s.step_time), 0))::numeric, 2)
           AS avg_step_seconds
FROM valid_cases v
CROSS JOIN step_dim d
LEFT JOIN registration_steps_final s
       ON s.case_id = v.case_id AND s.main_step = d.main_step
GROUP BY v.month, d.step_order, d.main_step, d.step_name
ORDER BY v.month, d.step_order;



/* Задание 3.
Когорта: один case_id по времени первого session / Sign In.
Успех: первое result / Submit > Response после старта до конца выгрузки.
Статус незавершения определяется на MAX(event_ts) выгрузки.
Последние старты июля наблюдаются меньше остальных; июль предварительный.
Ограничение 30 минут из задания 1 здесь не применяется.
*/

DROP TABLE IF EXISTS metric_cases;
CREATE TABLE metric_cases AS
WITH starts AS (
    SELECT case_id, MIN(event_ts) AS start_ts
    FROM events
    WHERE event_category = 'session' AND event_name = 'Sign In'
    GROUP BY case_id
), finishes AS (
    SELECT s.case_id, MIN(e.event_ts) AS finish_ts
    FROM starts s
    JOIN events e ON e.case_id = s.case_id
                 AND e.event_ts >= s.start_ts
                 AND e.event_category = 'result'
                 AND e.event_name = 'Submit > Response'
    GROUP BY s.case_id
)
SELECT s.case_id, s.start_ts,
       DATE_TRUNC('month', s.start_ts)::date AS month,
       f.finish_ts,
       COALESCE(f.finish_ts, (SELECT MAX(event_ts) FROM events)) AS end_ts
FROM starts s
LEFT JOIN finishes f USING (case_id);

DROP TABLE IF EXISTS metric_events;
CREATE TABLE metric_events AS
SELECT c.case_id, c.month, e.event_ts, e.event_category, e.event_name,
       CASE e.event_category
           WHEN 'nonResidentInfo' THEN 'taxResidentInfo'
           WHEN 'cardsDelivery' THEN 'cards'
           WHEN 'confirm' THEN 'summary'
           ELSE e.event_category
       END AS main_step
FROM metric_cases c
JOIN events e ON e.case_id = c.case_id
             AND e.event_ts BETWEEN c.start_ts AND c.end_ts
WHERE e.event_category IN (
    'main', 'identification', 'taxResidentInfo', 'nonResidentInfo',
    'addresses', 'employment', 'contacts', 'servicePackage',
    'cards', 'cardsDelivery', 'accessCard', 'summary', 'confirm',
    'questionnaire', 'docsUpload'
);

-- 1. Конверсия когорты стартовавших по состоянию на конец выгрузки.
SELECT month, COUNT(*) AS started_cases,
       COUNT(finish_ts) AS successful_cases,
       ROUND(100.0 * COUNT(finish_ts) / COUNT(*), 2) AS conversion_pct
FROM metric_cases
GROUP BY month
ORDER BY month;

/* 2. Последний экран кейсов без результата на конец выгрузки.
Это наблюдаемое место остановки.
no_screen означает, что после Sign In не зафиксировано ни одного экрана.
*/

WITH ranked AS (
    SELECT e.case_id, e.month, e.main_step,
           ROW_NUMBER() OVER (
               PARTITION BY e.case_id
               ORDER BY e.event_ts DESC, e.event_category DESC, e.event_name DESC
           ) AS rn
    FROM metric_events e
    JOIN metric_cases c ON c.case_id = e.case_id
    WHERE c.finish_ts IS NULL
), stopped AS (
    SELECT month, main_step, COUNT(*) AS stopped_cases
    FROM ranked
    WHERE rn = 1
    GROUP BY month, main_step
), reached AS (
    SELECT month, main_step, COUNT(DISTINCT case_id) AS reached_cases
    FROM metric_events
    GROUP BY month, main_step
)
SELECT r.month, r.main_step, r.reached_cases,
       COALESCE(s.stopped_cases, 0) AS stopped_cases,
       ROUND(100.0 * COALESCE(s.stopped_cases, 0) / r.reached_cases, 2)
           AS stop_pct
FROM reached r
LEFT JOIN stopped s ON s.month = r.month AND s.main_step = r.main_step
ORDER BY r.month, stop_pct DESC;

/* 3. Среднее время ответа: Click > Submit и непосредственно следующий
Submit > Response той же формы в одном кейсе.
Повторный клик до ответа оставляет предыдущий клик без пары.
*/

WITH ordered AS (
    SELECT month, case_id, event_category, main_step, event_ts, event_name,
           LEAD(event_ts) OVER w AS next_ts,
           LEAD(event_name) OVER w AS next_name
    FROM metric_events
    WHERE event_name IN ('Click > Submit', 'Submit > Response')
    WINDOW w AS (
        PARTITION BY case_id, event_category
        ORDER BY event_ts,
                 CASE WHEN event_name = 'Click > Submit' THEN 0 ELSE 1 END
    )
)
SELECT month, main_step, COUNT(*) AS submit_clicks,
       COUNT(*) FILTER (WHERE next_name = 'Submit > Response') AS paired_clicks,
       ROUND(100.0 * COUNT(*) FILTER (WHERE next_name = 'Submit > Response')
             / COUNT(*), 2) AS paired_pct,
       ROUND(AVG(EXTRACT(EPOCH FROM next_ts - event_ts))
             FILTER (WHERE next_name = 'Submit > Response')::numeric, 2)
             AS avg_response_seconds
FROM ordered
WHERE event_name = 'Click > Submit'
GROUP BY month, main_step
ORDER BY month, main_step;

-- 4. Несколько Submit: кейсы с двумя и более кликами на форме
-- / кейсы хотя бы с одним кликом на той же форме.
-- Возврат на экран тоже может вызвать повторное нажатие.
WITH clicks AS (
    SELECT month, case_id, event_category, COUNT(*) AS click_count
    FROM metric_events
    WHERE event_name = 'Click > Submit'
    GROUP BY month, case_id, event_category
)
SELECT month, event_category, COUNT(*) AS cases_with_submit,
       COUNT(*) FILTER (WHERE click_count > 1) AS cases_with_multiple_submits,
       ROUND(100.0 * COUNT(*) FILTER (WHERE click_count > 1)
             / COUNT(*), 2) AS multiple_submits_pct
FROM clicks
GROUP BY month, event_category
ORDER BY month, multiple_submits_pct DESC;


-- Проверка выводов задания 4. PostgreSQL.
-- Сначала в одной сессии выполните SQL заданий 1, 2 и 3.
-- Используются registration_cases_final, registration_steps_final,
-- metric_cases и metric_events.
-- Время успешных кейсов: месяц завершения, длительность 0–30 минут.
-- Остальные метрики: месяц первого Sign In, статус на конец выгрузки.

-- 1. Общее время и время двух этапов (секунды на успешный кейс).
-- Непройденный этап считается как 0, поэтому средние этапов сопоставимы.
SELECT DATE_TRUNC('month', c.finish_reg)::date AS month,
       COUNT(*) AS cases_in_average,
       ROUND(AVG(EXTRACT(EPOCH FROM c.total_reg))::numeric, 2)
           AS avg_total_sec,
       ROUND(AVG(COALESCE(EXTRACT(EPOCH FROM cards.step_time), 0))::numeric, 2)
           AS avg_cards_sec,
       ROUND(AVG(COALESCE(EXTRACT(EPOCH FROM docs.step_time), 0))::numeric, 2)
           AS avg_docs_sec
FROM registration_cases_final c
LEFT JOIN registration_steps_final cards
       ON cards.case_id = c.case_id AND cards.main_step = 'cards'
LEFT JOIN registration_steps_final docs
       ON docs.case_id = c.case_id AND docs.main_step = 'docsUpload'
WHERE c.total_reg BETWEEN INTERVAL '0 seconds' AND INTERVAL '30 minutes'
GROUP BY 1
ORDER BY 1;

-- 2. Конверсия: общий результат, но на неё влияет и состав клиентов.
SELECT month, COUNT(*) AS started_cases,
       COUNT(finish_ts) AS successful_cases,
       ROUND(100.0 * COUNT(finish_ts) / COUNT(*), 2) AS conversion_pct
FROM metric_cases
GROUP BY month
ORDER BY month;

-- 3. Остановки на идентификации среди дошедших до неё.
-- Последний экран показывает место остановки, а не причину.
WITH last_event AS (
    SELECT e.case_id, e.month, e.main_step,
           ROW_NUMBER() OVER (
               PARTITION BY e.case_id
               ORDER BY e.event_ts DESC, e.event_category DESC, e.event_name DESC
           ) AS rn
    FROM metric_events e
    JOIN metric_cases c ON c.case_id = e.case_id
    WHERE c.finish_ts IS NULL
), stopped AS (
    SELECT month, COUNT(*) AS stopped_on_identification
    FROM last_event
    WHERE rn = 1 AND main_step = 'identification'
    GROUP BY month
), reached AS (
    SELECT month, COUNT(DISTINCT case_id) AS reached_identification
    FROM metric_events
    WHERE main_step = 'identification'
    GROUP BY month
)
SELECT r.month, r.reached_identification,
       COALESCE(s.stopped_on_identification, 0)
           AS stopped_on_identification,
       ROUND(100.0 * COALESCE(s.stopped_on_identification, 0)
             / r.reached_identification, 2) AS stop_pct
FROM reached r LEFT JOIN stopped s USING (month)
ORDER BY r.month;

-- 4. Повторные нажатия Submit при прикреплении документов.
WITH clicks AS (
    SELECT month, case_id, COUNT(*) AS click_count
    FROM metric_events
    WHERE event_category = 'docsUpload' AND event_name = 'Click > Submit'
    GROUP BY month, case_id
)
SELECT month, COUNT(*) AS cases_with_submit,
       COUNT(*) FILTER (WHERE click_count > 1) AS multiple_submit_cases,
       ROUND(100.0 * COUNT(*) FILTER (WHERE click_count > 1)
             / COUNT(*), 2) AS multiple_submit_pct
FROM clicks
GROUP BY month
ORDER BY month;

-- 5. Среднее время отклика на черновике, только для найденных пар.
WITH ordered AS (
    SELECT month, case_id, event_category, event_ts, event_name,
           LEAD(event_ts) OVER w AS next_ts,
           LEAD(event_name) OVER w AS next_name
    FROM metric_events
    WHERE main_step = 'summary'
      AND event_name IN ('Click > Submit', 'Submit > Response')
    WINDOW w AS (
        PARTITION BY case_id, event_category
        ORDER BY event_ts,
                 CASE WHEN event_name = 'Click > Submit' THEN 0 ELSE 1 END
    )
)
SELECT month, COUNT(*) AS submit_clicks,
       COUNT(*) FILTER (WHERE next_name = 'Submit > Response') AS paired_clicks,
       ROUND(AVG(EXTRACT(EPOCH FROM next_ts - event_ts))
             FILTER (WHERE next_name = 'Submit > Response')::numeric, 2)
             AS avg_response_sec
FROM ordered
WHERE event_name = 'Click > Submit'
GROUP BY month
ORDER BY month;