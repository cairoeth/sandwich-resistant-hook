from manim import *

swaps = [
    [
        {
            'name': 'buy 1 unit of liquidity (attacker)',
            'base_pool': [1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1],
            'temp_pool': [1, 1, 2, 0, 0, 0, 1, 1, 1, 1, 1]
        },
        {
            'name': 'buy 3 units of liquidity (victim)',
            'base_pool': [1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1],
            'temp_pool': [1, 1, 5, 0, 0, 0, 0, 0, 0, 1, 1]
        },
        {
            'name': 'sell 1 unit of liquidity (attacker)',
            'base_pool': [1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1],
            'temp_pool': [1, 1, 4, 0, 0, 0, 0, 0, 1, 1, 1]
        }
    ],
    [
        {
            'name': 'buy 1 unit of liquidity (random)',
            'base_pool': [1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1],
            'temp_pool': [1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1]
        },
        {
            'name': '...',
            'base_pool': [1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1],
            'temp_pool': [1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1]
        },
        {
            'name': '...',
            'base_pool': [1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1],
            'temp_pool': [1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1]
        }
    ]
]

bar_names = ['p* - 4f', 'p* - 3f', 'p* - 2f', 'p* - f', 'p* + f',
             'p* + 2f', 'p* + 3f', 'p* + 4f', 'p* + 5f', 'p* + 6f', 'p* + 7f']
values = [1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1]


class Hook(Scene):
    def generate_table(self, swaps):
        num_blocks = len(swaps)
        num_swaps = max(len(block) for block in swaps)

        # Initialize the result list
        table_data = [[] for _ in range(num_swaps)]

        # Iterate through each block (column) in swaps
        for block in swaps:
            for i, item in enumerate(block):
                table_data[i].append(item['name'])

        col_labels = [Text(f"Block {i+1}") for i in range(num_blocks)]
        row_labels = [Text(str(i+1)) for i in range(num_swaps)]

        table = Table(
            table_data,
            row_labels=row_labels,
            col_labels=col_labels,
            include_outer_lines=True
        ).scale(0.35).shift(2.05 * UP)

        return table

    def generate_colors(self, values):
        colors = []
        found_zero = False

        for value in values:
            if value == 0:
                colors.append("BLUE")
                found_zero = True
            elif not found_zero:
                colors.append("GREEN")
            else:
                colors.append("RED")

        return colors

    def construct(self):
        text = Text("Sandwich-Resistant Hook").scale(1.5)
        self.play(Write(text))
        self.wait(1)
        self.play(text.animate.shift(3.5 * UP).scale(0.5))

        # blocks
        table = self.generate_table(swaps)
        self.play(DrawBorderThenFill(table))
        self.wait()

        pool_text = Text("Highlighted state is used for swap delta",
                         color=YELLOW).scale(0.4).next_to(table, 1.1 * DOWN)
        self.play(Write(pool_text))

        base_pools = VGroup()
        temp_pools = VGroup()

        # base pool
        base_pool = BarChart(
            values=values,
            bar_names=bar_names,
            bar_colors=self.generate_colors(values),
            bar_width=1,
            y_range=[0, 6, 1], axis_config={"include_ticks": False, "include_tip": False}
        ).scale(0.5).shift(2 * DOWN).shift(3.3 * LEFT)
        base_pools.add(base_pool)

        # temp pool
        temp_pool = BarChart(
            values=values,
            bar_names=bar_names,
            bar_colors=self.generate_colors(values),
            bar_width=1,
            y_range=[0, 6, 1], axis_config={"include_ticks": False, "include_tip": False}
        ).scale(0.5).shift(2 * DOWN).shift(3.7 * RIGHT)
        temp_pools.add(temp_pool)

        self.play(Create(VGroup(base_pool, temp_pool)))

        base_title = Text('Base State').scale(0.5).next_to(base_pool, UP)
        temp_title = Text('Temporary State (resets every block)').scale(
            0.5).next_to(temp_pool, UP)
        self.play(Write(VGroup(base_title, temp_title)))
        self.wait(1)

        base_highlight = SurroundingRectangle(
            VGroup(base_pool, base_title), color=YELLOW, buff=MED_LARGE_BUFF)
        temp_highlight = SurroundingRectangle(
            VGroup(temp_pool, temp_title), color=YELLOW, buff=MED_LARGE_BUFF)

        # play swaps
        try:
            for i in range(0, len(swaps)):
                for j in range(len(swaps[i])):
                    row, col = j + 2, i + 2
                    if i == 1 and j > 0:
                        raise Exception('end')

                    cur_cell = table.get_cell((row, col), color=YELLOW)
                    self.play(FadeIn(cur_cell, run_time=0.3))

                    new_values = swaps[i][j]['base_pool']
                    base_pools.add(BarChart(
                        values=new_values,
                        bar_names=bar_names,
                        bar_colors=self.generate_colors(new_values),
                        bar_width=1,
                        y_range=[0, 6, 1], axis_config={"include_ticks": False, "include_tip": False}
                    ).scale(0.5).shift(2 * DOWN).shift(3.3 * LEFT))

                    # highlight base pool
                    if row == 2:
                        print('first swap in block')
                        self.play(FadeIn(base_highlight))

                        # execute swap on base pool
                        self.play(ReplacementTransform(
                            base_pools[-2], base_pools[-1], run_time=1))
                        self.wait(1)

                        # execute swap on temp pool
                        new_values_temp = swaps[i][j]['temp_pool']
                        temp_pools.add(BarChart(
                            values=new_values_temp,
                            bar_names=bar_names,
                            bar_colors=self.generate_colors(new_values_temp),
                            bar_width=1,
                            y_range=[0, 6, 1], axis_config={"include_ticks": False, "include_tip": False}
                        ).scale(0.5).shift(2 * DOWN).shift(3.7 * RIGHT))
                        self.play(ReplacementTransform(
                            temp_pools[-2], temp_pools[-1], run_time=1))

                        self.wait(1)
                        self.play(FadeOut(base_highlight))
                    # highlight both base and temp pool
                    else:
                        print('swap in block')
                        self.play(FadeIn(temp_highlight))

                        # execute swap on temp pool
                        new_values_temp = swaps[i][j]['temp_pool']
                        temp_pools.add(BarChart(
                            values=new_values_temp,
                            bar_names=bar_names,
                            bar_colors=self.generate_colors(new_values_temp),
                            bar_width=1,
                            y_range=[0, 6, 1], axis_config={"include_ticks": False, "include_tip": False}
                        ).scale(0.5).shift(2 * DOWN).shift(3.7 * RIGHT))
                        self.play(ReplacementTransform(
                            temp_pools[-2], temp_pools[-1], run_time=1))

                        # execute swap on base pool
                        self.play(ReplacementTransform(
                            base_pools[-2], base_pools[-1], run_time=1))

                        self.wait(1)
                        self.play(FadeOut(temp_highlight))

                    self.play(FadeOut(cur_cell))
        except:
            pass
