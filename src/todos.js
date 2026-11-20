'use strict';

// Pure functions over the in-memory list {nextId, items: [{id, text, done}]}. None mutate their input.

// Returns a new state with an open item whose id is state.nextId, and nextId one higher.
function addItem(state, text) {
  const item = { id: state.nextId, text, done: false };
  return { nextId: state.nextId + 1, items: [...state.items, item] };
}

// Returns the open (not done) items in ascending id order, as a new array.
function openItems(state) {
  return state.items.filter((item) => !item.done).sort((a, b) => a.id - b.id);
}

module.exports = { addItem, openItems };
