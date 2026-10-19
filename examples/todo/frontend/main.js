// The client is generated from the Zig services (`--myzig-generate`, see
// myzig.d.ts for its types): calls and payloads are typed.
import { Todos, onChanged } from "/myzig.js";

const $ = (selector) => document.querySelector(selector);

let filter = "all";

export async function render() {
  const [todos, stats] = await Promise.all([Todos.list(filter), Todos.stats()]);
  $("#list").replaceChildren(...todos.map(renderItem));
  $("#count").textContent = `${stats.active} of ${stats.total} left`;
}

function renderItem(todo) {
  const li = $("#item").content.firstElementChild.cloneNode(true);
  li.classList.toggle("done", todo.done);
  const box = li.querySelector("input");
  box.checked = todo.done;
  box.addEventListener("change", () => run(Todos.toggle(todo.id)));
  li.querySelector("span").textContent = todo.title;
  li.querySelector(".remove").addEventListener("click", () => run(Todos.remove(todo.id)));
  return li;
}

// Reports errors returned by Zig methods.
async function run(p) {
  try {
    await p;
    $("#error").textContent = "";
  } catch (err) {
    $("#error").textContent = err instanceof Error ? err.message : String(err);
  }
}

$("#add").addEventListener("submit", (e) => {
  e.preventDefault();
  const input = $("#title");
  run(Todos.add(input.value).then(() => (input.value = "")));
});

$("#filters").addEventListener("click", (e) => {
  const button = e.target.closest("button[data-filter]");
  if (!button) return;
  filter = button.dataset.filter;
  document.querySelectorAll("#filters button").forEach((b) => b.classList.toggle("active", b === button));
  render();
});

$("#clear").addEventListener("click", () => run(Todos.clearDone()));
$("#export").addEventListener("click", () => run(Todos.export()));

// Changes made in any window (or from the menu) are broadcast by Zig.
onChanged(() => render());

render();
