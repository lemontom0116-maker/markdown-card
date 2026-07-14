const CHECKBOX_PATTERN = /^\[([ xX])\][ \t]+/;

function addClass(token, className) {
  const classes = new Set((token.attrGet("class") ?? "").split(/\s+/).filter(Boolean));
  classes.add(className);
  token.attrSet("class", [...classes].join(" "));
}

export function taskListPlugin(md) {
  md.core.ruler.after("inline", "markdown_card_task_lists", (state) => {
    const stack = [];

    for (let index = 0; index < state.tokens.length; index += 1) {
      const token = state.tokens[index];

      if (token.nesting === 1) {
        stack.push(index);
      }

      if (token.type === "inline" && token.children?.length) {
        const firstText = token.children.find((child) => child.type === "text");
        const match = firstText?.content.match(CHECKBOX_PATTERN);

        if (match) {
          const listItemIndex = [...stack]
            .reverse()
            .find((candidate) => state.tokens[candidate].type === "list_item_open");
          const listIndex = [...stack]
            .reverse()
            .find((candidate) =>
              ["bullet_list_open", "ordered_list_open"].includes(
                state.tokens[candidate].type
              )
            );

          if (listItemIndex !== undefined && listIndex !== undefined) {
            firstText.content = firstText.content.slice(match[0].length);

            const checkbox = new state.Token("task_checkbox", "input", 0);
            checkbox.meta = { checked: match[1].toLowerCase() === "x" };
            token.children.unshift(checkbox);

            addClass(state.tokens[listItemIndex], "task-list-item");
            addClass(state.tokens[listIndex], "task-list");
          }
        }
      }

      if (token.nesting === -1) {
        stack.pop();
      }
    }
  });

  md.renderer.rules.task_checkbox = (tokens, index) => {
    const checked = tokens[index].meta?.checked ? " checked" : "";
    const label = tokens[index].meta?.checked ? "Completed task" : "Incomplete task";

    return `<input class="task-checkbox" type="checkbox" disabled${checked} aria-label="${label}">`;
  };
}
