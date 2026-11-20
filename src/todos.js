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

// Returns every item, open and done, in ascending id order, as a new array.
function allItems(state) {
  return [...state.items].sort((a, b) => a.id - b.id);
}

// Returns a new state with item `id` marked done, or null when no item has that id.
// Marking an already-done item returns an equal state (a no-op).
function markDone(state, id) {
  if (!state.items.some((item) => item.id === id)) return null;
  return {
    nextId: state.nextId,
    items: state.items.map((item) => (item.id === id ? { ...item, done: true } : item)),
  };
}

module.exports = { addItem, openItems, allItems, markDone };
