# Auto Factory Planner

**Public alpha · 0.3.41 · Factorio 2.1.23+ · EN / RU · MIT**

Choose what to make, resolve its ingredients, and generate a factory blueprint or manage a factory through a placed controller. Production layouts use researched recipes and equipment from the active game. **Space Age is optional.**

## English

### Features

- Rate mode: choose one or more products, each with its own items per minute.
- Mall mode: choose several products and stock targets in stacks, with one final assembler per product and output chests beside production.
- Choose recipes, machines and external supplies in the production-chain editor.
- Dense production rows, shared ingredient belts, direct insertion and local transport branches. External inputs keep their order; outputs are separate.
- Automatic speed selection for each belt and splitter by its local lane load; underground pairs also account for tunnel length. Yellow, red and faster segments can share one route.
- Recursive belt routing minimizes full route length, then turns. Underground spans count over their entire length. A forward flow check verifies supply, consumer demand and lane capacity after routing.
- Place, move and turn individual belt/fluid connections on the map, then recalculate and review before applying; each connection can return to automatic placement.
- Place production first with the required clearance from the controller and roads, then route external connections. Selecting or moving a connection does not reposition production.
- Reverse recycler recipes are hidden by default. Enable **Show recycling recipes** in the production chain to include them in the list and automatic selection.
- Choose one factory growth direction: north, east, south or west. The external main bus is supplied by the player.
- Limit plot width; roboport grid roads are always four tiles wide and centred on the grid lines. Manual production rows and their intake forks start behind the inner edge of the first road; selected external connections stay fixed. Choose their paving material in Layout.
- Mark trees and rocks for robot removal only where they collide with planned entities; preserve terrain in empty gaps and on roads.
- Demolish a factory from any controller tab: cancel its ghosts and send robots to remove its own buildings and paving, keeping the controller and settings.
- Review generation steps and the objects to keep, build and remove before applying an update.
- Compression minimizes a weighted sum of allocated city blocks, factory perimeter, factory area and entity unit price (excluding paving tiles). **Layout** exposes all four nonnegative coefficients; zero disables a criterion. Defaults: `10000 × blocks + 10 × perimeter + area + entity unit price`. Long intermediate rows can also be divided into neighbouring banks; placement leaves space for the next bank before routing. Where capacities match, intermediate banks feed their own consumers directly, without a shared merge-and-fork tree. After choosing the initial layout, compression moves production sections one tile closer and reroutes all connections. This includes separate banks of a single solid-item recipe: their machine counts and proportional demand are preserved, while feed and collector routes are rebuilt. Eligible opposite rows share two adjacent central belts: a mixed ingredient feed and an export belt, served by ordinary and long-handed inserters. The planner compares producer orientations and ingredient lane assignments, checks arm throughput and researched equipment, and keeps the existing feed-and-splitter alternatives when needed. Other compatible two-ingredient banks share one lane mixer and one splitter tree. The ingredient sources may be external inputs or upstream production inside the same factory. Opposite banks can unload onto the two lanes of a common belt; compression joins matching collector stripes without overlapping the machines or inserters. A higher unit price is rolled back and that direction stops; valid non-increasing moves continue until no further move is accepted. Base-tier prices: belt 1; each underground endpoint 3; splitter 10. Each successive transport tier costs 1.5 times the previous one (yellow/red/blue/green belts: 1/1.5/2.25/3.375). Tiers follow distinct prototype speeds within each transport family, independently of research; equal-speed variants have the same price. Other entities cost 1. The preview shows quantity, unit price, grid metrics and total score. Adjacent units of one factory share a perimeter road, keeping production rows clear of internal measuring lines.
- New plans use the roboport-sized grid before robotics research. The grid, controller snapping and four-tile road corridors are available immediately; locked roboports are omitted from construction.
- The primary city block is the world grid cell containing the factory controller. Production starts inside that cell with a one-tile setback from the inner road edge. Applying a plan places the controller in a free inner corner of that service band, preserving all four roboport corners; a blocked corner never shifts the factory into another cell.
- In grid plans, automatic solid-product outputs run backwards, against factory growth, beyond the entrance road. Opposite banks reverse their common collector directly. Manually selected output positions take priority.
- Existing inputs stay fixed; matching buildings and belts remain when the factory is updated. New inputs are appended.
- Complete rectangular grids of connected, powered roboports. Factory width is capped by the spacing between neighbouring ports (50 tiles for the standard roboport). Craft **Roboport grid reference** or use **Choose reference roboport** in Layout, then select a built roboport to set the grid origin. Existing reference ports are reused.
- Power planning removes redundant supply poles, reuses the intake connection and joins nearby network components first. Automatic selection uses researched long-distance poles where they reduce relay count; an explicit pole choice remains fixed.
- Local power refinement moves neighbouring supply poles into shared positions. Automatic supply selection also compares researched substations that fit inside the existing factory footprint, powering both banks without moving production or transport.
- Copy controller settings with the game's copy/paste settings controls. New factories remember your last growth direction.

### Quick start

1. Install the mod and enable it in Factorio. It requires the **2.1 branch, version 2.1.23 or newer**; it does not support Factorio 2.0.
2. Craft and place a **Factory controller**, then open it. For a standalone rate blueprint, use the shortcut or **Ctrl+Shift+F**.
3. In **Production**, click **+** to add a product, choose its recipe and machine from the icon grids, then click the product to set its rate or stock. Ingredients appear as external inputs immediately; click an ingredient to choose its local recipe and machine. Click a machine to replace it.
4. In **Layout**, choose the growth direction, width, equipment and optional roboports/paving. The factory grid is enabled by default; **Place controller on grid** also works before robotics research.
5. Calculate the layout, review **Update**, and apply it. A managed factory places construction ghosts; a standalone rate plan gives you a blueprint.
6. Connect the marked external inputs and electric network. Supply construction materials and robots through normal gameplay. Mall chests stop production naturally when their allowed slots are full.

Byproducts appear between products and external inputs. Click one to move it into outputs or add consuming recipes. Set each recipe's source consumption per minute manually; the remaining material is exported.

After changing a controller's settings, calculate and apply again. Copying settings changes the recipient's draft; it does not immediately rebuild its factory.

Mixed item/fluid chains use local production groups: underground belts pass through machine footprints, pickup points sit between machines, and fluid connections approach from the sides. Expanding intermediates stay near their consumers; direct-insertion ratios are calculated from recipe rates and machine sizes.

Rate plans enable **Compact layout search** unless explicitly disabled. The new geometry engine places dense production blocks, joins them directly, and adds local splitters only for shared streams. A factory with one recipe keeps the normal row orientation. Its two production rows unload onto one shared belt between them. It compares production candidates independently of external connection lengths, uses the force's actual inserter capacity bonuses, and preserves fixed external inputs. Add more rate targets with **+** in **Production**; they share one material balance and factory.

### Alpha limitations

- Modules, beacons and higher qualities are not planned. Spoilage, heating and interplanetary transport are not modelled.
- Recipe and machine discovery is generic, but unusual modded inventories, inserters or fluid connections may need additional support. Compatibility with every overhaul is not claimed.
- Surface-specific recipe/building restrictions are not validated by the planner. Use a suitable surface when placing a plan.
- Layout search has limits; large chains may take a long time or fail to route. The result is a compact candidate, not a guaranteed minimum-area layout.
- Up to 150 selected processes, 300 machines per process, 32 parallel sections and 30,000 blueprint entities. A fluid network is limited to 300 tiles per axis; automatic segmentation by pumps is not implemented.
- Mall requires a placed controller. Standalone mall blueprint export is not supported.

### Feedback

Use the mod's **Discussion** tab on Mod Portal. Include the mod/game versions, enabled mods, target products and rates/stocks, selected recipes/equipment, directions and width. For a generation error, include its screenshot and relevant `factorio-current.log` excerpt; a small reproducible save is helpful.

## Русский

Мод строит план по выбранным продуктам, рецептам и открытым технологиям. **Space Age не обязателен.** Работает на ветке **Factorio 2.1, начиная с 2.1.23**.

В режиме скорости можно добавить несколько продуктов кнопкой **«+»** во вкладке **«Производство»** и задать каждому выпуск в минуту. Они рассчитываются совместно и собираются в один завод. **«Компактная компоновка»** включена, пока её явно не отключили. Новое ядро размещает плотные производственные блоки и соединяет их напрямую; разветвители добавляются для общих потоков. Завод с одним рецептом сохраняет обычную ориентацию рядов. В двухрядной схеме оба ряда выгружают на один общий конвейер между ними. Сравниваются полностью разведённые варианты, учитываются исследования вместимости манипуляторов, порядок и фиксированные позиции внешних входов.

### Начало работы

Робопорты размещаются полной прямоугольной сеткой. Ширина фабрики ограничена расстоянием между соседними робопортами (50 клеток для обычного робопорта). Создайте предмет **«Привязка сетки к робопорту»** или нажмите **«Выбрать опорный робопорт»** в компоновке и выделите построенный робопорт. Сетка будет отсчитываться от его положения; существующие робопорты используются без дубликатов. Дорожки всегда имеют ширину 4 клетки и проходят по центру линий сетки, в том числе под робопортами. Материал мощения выбирается в компоновке.

Планировщик ЛЭП убирает лишние опоры питания, использует ближайшую опору для подключения у входа и сначала соединяет соседние участки сети. При автоматическом выборе изученные большие опоры сокращают число промежуточных столбов; явно выбранный тип опоры сохраняется.

Уточнение локального питания сближает и объединяет соседние опоры. Автоматический выбор сравнивает и изученные подстанции, которые помещаются внутри существующей площади завода: они могут питать оба ряда без переноса зданий или конвейеров. Явно выбранный тип опор сохраняется.

Первичный ситиблок — ячейка мировой сетки, в которой находится контроллер завода. Производство начинается внутри неё с отступом в одну клетку от внутреннего края дорожек. При применении плана контроллер занимает свободный внутренний угол этой полосы, сохраняя все четыре площадки робопортов. Занятый угол не переносит завод в другую ячейку.

В планах по сетке автоматические выходы твёрдой продукции идут назад, против направления роста завода, за входную дорожку. Общий конвейер встречных рядов разворачивается в эту сторону. Указанные вручную места выходов имеют приоритет.

В новых планах сетка включена сразу, даже до исследования робототехники. Привязка контроллера и проходы уже доступны; неизученные робопорты не добавляются в строительство. Этап **«Сжатие»** минимизирует взвешенную сумму: число занятых ячеек сетки, периметр завода, площадь завода и условную цену объектов без плиток покрытия. Четыре неотрицательных коэффициента доступны в **«Компоновке»**; ноль отключает критерий. По умолчанию: `10000 × ситиблоки + 10 × периметр + площадь + цена объектов`. Длинные ряды промежуточных производств тоже могут разбиваться на соседние блоки; место для следующего блока учитывается до прокладки соединений. Если мощности позволяют, промежуточные блоки питают своих потребителей напрямую, без общего слияния и повторного разделения потока. После первоначальной компоновки сжатие сдвигает производственные секции на клетку ближе и заново прокладывает соединения. Это работает и между рядами одного рецепта с твёрдыми предметами: число машин и доли потребления сохраняются, подача и сбор продукции прокладываются заново. При подходящей мощности встречные ряды используют два соседних конвейера посередине: смешанную подачу ингредиентов и сбор продукции, с обычными и длинными манипуляторами. Планировщик сравнивает ориентации предшествующего производства и порядок ингредиентов, проверяет пропускную способность и доступные исследования; при необходимости сохраняет прежние варианты подачи. Другие совместимые ряды с двумя ингредиентами используют одно объединение на две полосы и общее дерево разделения. Ингредиенты могут поступать снаружи или из предыдущего производства внутри завода. Встречные ряды могут выгружать продукцию на две полосы одного конвейера; сжатие совмещает выходные линии, сохраняя раздельные места для машин и манипуляторов. Сдвиг с ростом условной цены откатывается, и дальнейшее сближение в этом направлении прекращается. Базовые цены: конвейер — 1, каждый конец подземного конвейера — 3, разделитель — 10. Каждый следующий тир транспорта стоит в 1,5 раза дороже предыдущего: жёлтый/красный/синий/зелёный конвейер — 1/1,5/2,25/3,375. Тиры определяются разными скоростями прототипов внутри каждого вида транспорта и не зависят от исследований; варианты одной скорости стоят одинаково. Остальные объекты стоят 1. Количество объектов, цена, итоговая оценка и границы ячеек видны в предпросмотре. Соседние ячейки одного завода объединяются общим периметром дорог; внутренние линии измерительной сетки не перекрывают производство.

Обратные рецепты переработчиков по умолчанию скрыты. Галочка **«Показывать рецепты переработки»** во вкладке **«Цепочка»** включает их в список и автоподбор. Уже выбранные рецепты сохраняются при выключении галочки.

Скорость каждого отдельного конвейера и разделителя выбирается автоматически по нагрузке на стороны ленты. После забора и слияния потоков цвет может меняться. Подземная пара также учитывает длину перехода и использует одинаковый тип на обоих концах.

Рекурсивный поиск конвейерных маршрутов сначала минимизирует полную длину, затем число поворотов. Подземный участок считается по всей длине. После построения сети проверяются подача, потребность потребителей и пропускная способность сторон ленты от источников к потребителям.

Сначала производство размещается относительно контроллера и дорожек с необходимым минимальным отступом, затем к нему прокладываются подключения. Выбор и перенос входов или выходов не сдвигает производство.

Во вкладке **«Компоновка» → «Ручные подключения»** у каждого входа и конвейерного/жидкостного выхода можно нажать **«Разместить»** или **«Перенести»** и выбрать свободную клетку на карте. **R** меняет направление при выборе; **«Повернуть»** меняет направление сохранённой точки, **«Авто»** возвращает автоматическое размещение. Очистка курсора отменяет выбор. Затем пересчитайте план, проверьте изменения и примените их. Контроллер сохраняет выбранные мировые координаты при обновлении, а освободившиеся продолжения маршрутов удаляются обычным обновлением. Выходы товаров молла остаются сундуками запаса у сборщиков.

1. Создайте и поставьте **Контроллер завода**, затем откройте его. Для отдельного блюпринта обычной цепочки используйте кнопку панели или **Ctrl+Shift+F**.
2. Во вкладке **«Производство»** нажмите **«+»**, выберите товар, рецепт и машину из сеток иконок. Нажатие на товар открывает скорость в штуках/мин либо запас mall в стаках. У каждого конечного товара mall один сборщик и выходной сундук рядом с производством.
3. Ингредиенты сразу появляются во **«Внешней подаче»**. Нажмите на ингредиент, чтобы выбрать его рецепт и машину для производства здесь. Нажатие на иконку машины открывает выбор замены.
4. В **«Компоновке»** выберите **«Направление роста завода»**, ширину и оборудование. Робопорты и мощение включаются отдельно. Кнопка **«Поставить контроллер по сетке»** выдаёт блюпринт с нативной привязкой.
5. Рассчитайте схему, проверьте изменения во вкладке **«Обновление»** и примените. Контроллер размещает призраки; для отдельного плана можно получить блюпринт.
6. Подключите обозначенные входы и электричество. Ресурсы, строительные материалы и роботов обеспечивает игрок. Основную внешнюю магистраль мод не создаёт.

Побочные продукты показаны между товарами и внешней подачей. Нажмите на ресурс, чтобы перенести его в выходы или добавить рецепты переработки. Расход исходного ресурса в минуту задаётся вручную для каждого рецепта; оставшийся поток выводится наружу.

При обновлении входы сохраняют координаты, новые добавляются в конце, подходящие объекты остаются. Свободный отступ в две клетки резервируется всегда; мощение необязательно. Настройки контроллеров копируются стандартными действиями игры: по умолчанию **Shift+ПКМ → Shift+ЛКМ**. После копирования нужно пересчитать и применить план.

При применении плана через контроллер на снос роботами помечаются только деревья и камни, мешающие конкретным объектам плана. Деревья и камни в свободных промежутках и на дорожках сохраняются. После удаления препятствий строительство продолжается автоматически.

Кнопка **«Снос»** доступна на всех вкладках контроллера. Она отменяет строительные призраки и выдаёт роботам задания на демонтаж объектов и мощения этого завода. Контроллер и настройки сохраняются; для восстановления рассчитайте и примените план снова.

В смешанных предметно-жидкостных цепочках подземные конвейеры проходят под зданиями, а точки забора находятся между машинами. Жидкости подключаются сбоку. Промежуточные продукты размещаются рядом с потребителями; соотношения прямой подачи рассчитываются по рецептам, скорости и габаритам зданий.

### Ограничения альфы

Модули, маяки, повышенное качество, порча продуктов, нагрев и межпланетная логистика не рассчитываются. Ограничения рецептов и зданий по поверхности не проверяются. Нестандартные прототипы других модов могут потребовать доработки. Большие цепочки могут долго рассчитываться или не проложиться; глобально минимальная площадь не гарантируется. Пределы: 150 процессов, 300 машин на процесс, 32 секции, 30 000 объектов; жидкостная сеть — до 300 клеток по каждой оси. Mall работает через контроллер.

Для сообщения об ошибке используйте **Discussion** на Mod Portal. Укажите версии, список модов, товары и скорости/запасы, рецепты, оборудование, направления и ширину. Приложите ошибку, фрагмент `factorio-current.log` и по возможности небольшой пример сохранения.

## Development

The repository contains the native Factorio regression fixtures in `tests/`, isolated test runners and the release builder in `tools/`. Run `python tools/verify.py` and `python tools/package.py`. Test without the expansion using `tools/project-test.ps1 -BaseOnly` and `tools/generation-test.ps1 -BaseOnly`. `tools/mixed-test.ps1` checks mixed-chain geometry, stable input updates and native throughput; pass `-BaseOnly` to test without Space Age. Detailed development history and earlier test notes are in [docs/development.md](docs/development.md); public changes are in [changelog.txt](changelog.txt).

`tools/oil-test.ps1 -Capture` builds the advanced-oil example with six manual outlets to the left of the entrance road: petroleum gas 10,000/min, light oil 1,000/min, sulfur and plastic 900/min each, lubricant and sulfuric acid 60/min each. It verifies a native blueprint build and simultaneous throughput after the initially empty pipe networks fill, then captures the factory and outlet details. Use `-Reuse` to rerun an existing fixture.

The oil fixture also checks that all ten world connections stay fixed and no surface entity occupies either side road. Its sulfur outlet is a red belt tested with a demand of 450/min on each lane; the internal acid branch consumes another 6/min near the sulfur plants.

Code and original controller/thumbnail artwork: **MIT**, copyright 2026 DefGh. Factorio and screenshots of its game assets remain the property of Wube Software; see [release/credits.txt](release/credits.txt) in the source repository.
