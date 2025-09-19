#ifndef _IH_LIST_H
#define _IH_LIST_H

#include <string.h>

/*
 * These are non-NULL pointers that will result in page faults
 * under normal circumstances, used to verify that nobody uses
 * non-initialized list entries.
 */
#define IH_LIST_POISON1  ((void *) 0x00100100)
#define IH_LIST_POISON2  ((void *) 0x00200200)

#define ih_offsetof(TYPE, MEMBER) ((size_t) &((TYPE *)0)->MEMBER)

/**
 * ih_container_of - cast a member of a structure out to the containing structure
 * @ptr:        the pointer to the member.
 * @type:       the type of the container struct this is embedded in.
 * @member:     the name of the member within the struct.
 *
 */
#define ih_container_of(ptr, type, member) ({                      \
	const typeof( ((type *)0)->member ) *__mptr = (ptr);    \
	(type *)( (char *)__mptr - ih_offsetof(type,member) );})

/*
 * Simple doubly linked list implementation.
 *
 * Some of the internal functions ("__xxx") are useful when
 * manipulating whole lists rather than single entries, as
 * sometimes we already know the next/prev entries and we can
 * generate better code by using them directly rather than
 * using the generic single-entry routines.
 */

struct ih_list_head {
	struct ih_list_head *next, *prev;
};

#define IH_LIST_HEAD_INIT(name) { &(name), &(name) }

#define IH_LIST_HEAD(name) \
	struct ih_list_head name = IH_LIST_HEAD_INIT(name)

static inline void IH_INIT_LIST_HEAD(struct ih_list_head *list)
{
	list->next = list;
	list->prev = list;
}

/*
 * Insert a new entry between two known consecutive entries.
 *
 * This is only for internal list manipulation where we know
 * the prev/next entries already!
 */
static inline void __ih_list_add(struct ih_list_head *new_l,
			      struct ih_list_head *prev,
			      struct ih_list_head *next)
{
	next->prev = new_l;
	new_l->next = next;
	new_l->prev = prev;
	prev->next = new_l;
}

/**
 * ih_list_add - add a new entry
 * @new: new entry to be added
 * @head: list head to add it after
 *
 * Insert a new entry after the specified head.
 * This is good for implementing stacks.
 */
static inline void ih_list_add(struct ih_list_head *new_l, struct ih_list_head *head)
{
	__ih_list_add(new_l, head, head->next);
}


/**
 * ih_list_add_tail - add a new entry
 * @new: new entry to be added
 * @head: list head to add it before
 *
 * Insert a new entry before the specified head.
 * This is useful for implementing queues.
 */
static inline void ih_list_add_tail(struct ih_list_head *new_l, struct ih_list_head *head)
{
	__ih_list_add(new_l, head->prev, head);
}

/*
 * Delete a list entry by making the prev/next entries
 * point to each other.
 *
 * This is only for internal list manipulation where we know
 * the prev/next entries already!
 */
static inline void __ih_list_del(struct ih_list_head * prev, struct ih_list_head * next)
{
	next->prev = prev;
	prev->next = next;
}

/**
 * ih_list_del - deletes entry from list.
 * @entry: the element to delete from the list.
 * Note: ih_list_empty() on entry does not return true after this, the entry is
 * in an undefined state.
 */
static inline void ih_list_del(struct ih_list_head *entry)
{
	__ih_list_del(entry->prev, entry->next);
	entry->next =(struct ih_list_head*)IH_LIST_POISON1;
	entry->prev =(struct ih_list_head*)IH_LIST_POISON2;
}

/**
 * ih_list_free - free list
 * @head:	the head for your list.
 * @type:	the type of entries
 * @member:	the name of the list_struct within the struct.
 */
#define ih_list_free(head, type, member){ \
	type *node, *n; \
	ih_list_for_each_entry_safe(node, n, head, member) { \
		ih_list_del(&node->list); \
		free(node); \
	}}

/**
 * ih_list_replace - replace old entry by new one
 * @old : the element to be replaced
 * @new : the new element to insert
 *
 * If @old was empty, it will be overwritten.
 */
static inline void ih_list_replace(struct ih_list_head *old,
				struct ih_list_head *new_l)
{
	new_l->next = old->next;
	new_l->next->prev = new_l;
	new_l->prev = old->prev;
	new_l->prev->next = new_l;
}

static inline void ih_list_replace_init(struct ih_list_head *old,
					struct ih_list_head *new_l)
{
	ih_list_replace(old, new_l);
	IH_INIT_LIST_HEAD(old);
}

/**
 * ih_list_del_init - deletes entry from list and reinitialize it.
 * @entry: the element to delete from the list.
 */
static inline void ih_list_del_init(struct ih_list_head *entry)
{
	__ih_list_del(entry->prev, entry->next);
	IH_INIT_LIST_HEAD(entry);
}

/**
 * ih_list_move - delete from one list and add as another's head
 * @list: the entry to move
 * @head: the head that will precede our entry
 */
static inline void ih_list_move(struct ih_list_head *list, struct ih_list_head *head)
{
	__ih_list_del(list->prev, list->next);
	ih_list_add(list, head);
}

/**
 * ih_list_move_tail - delete from one list and add as another's tail
 * @list: the entry to move
 * @head: the head that will follow our entry
 */
static inline void ih_list_move_tail(struct ih_list_head *list,
				  struct ih_list_head *head)
{
	__ih_list_del(list->prev, list->next);
	ih_list_add_tail(list, head);
}

/**
 * ih_list_is_last - tests whether @list is the last entry in list @head
 * @list: the entry to test
 * @head: the head of the list
 */
static inline int ih_list_is_last(const struct ih_list_head *list,
				const struct ih_list_head *head)
{
	return list->next == head;
}

/**
 * ih_list_empty - tests whether a list is empty
 * @head: the list to test.
 */
static inline int ih_list_empty(const struct ih_list_head *head)
{
	return head->next == head;
}

/**
 * ih_list_empty_careful - tests whether a list is empty and not being modified
 * @head: the list to test
 *
 * Description:
 * tests whether a list is empty _and_ checks that no other CPU might be
 * in the process of modifying either member (next or prev)
 *
 * NOTE: using ih_list_empty_careful() without synchronization
 * can only be safe if the only activity that can happen
 * to the list entry is ih_list_del_init(). Eg. it cannot be used
 * if another CPU could re-ih_list_add() it.
 */
static inline int ih_list_empty_careful(const struct ih_list_head *head)
{
	struct ih_list_head *next = head->next;
	return (next == head) && (next == head->prev);
}

/**
 * ih_list_is_singular - tests whether a list has just one entry.
 * @head: the list to test.
 */
static inline int ih_list_is_singular(const struct ih_list_head *head)
{
	return !ih_list_empty(head) && (head->next == head->prev);
}

static inline void __ih_list_cut_position(struct ih_list_head *list,
		struct ih_list_head *head, struct ih_list_head *entry)
{
	struct ih_list_head *new_first = entry->next;
	list->next = head->next;
	list->next->prev = list;
	list->prev = entry;
	entry->next = list;
	head->next = new_first;
	new_first->prev = head;
}

/**
 * ih_list_cut_position - cut a list into two
 * @list: a new list to add all removed entries
 * @head: a list with entries
 * @entry: an entry within head, could be the head itself
 *	and if so we won't cut the list
 *
 * This helper moves the initial part of @head, up to and
 * including @entry, from @head to @list. You should
 * pass on @entry an element you know is on @head. @list
 * should be an empty list or a list you do not care about
 * losing its data.
 *
 */
static inline void ih_list_cut_position(struct ih_list_head *list,
		struct ih_list_head *head, struct ih_list_head *entry)
{
	if (ih_list_empty(head))
		return;
	if (ih_list_is_singular(head) &&
		(head->next != entry && head != entry))
		return;
	if (entry == head)
		IH_INIT_LIST_HEAD(list);
	else
		__ih_list_cut_position(list, head, entry);
}

static inline void __ih_list_splice(const struct ih_list_head *list,
				 struct ih_list_head *prev,
				 struct ih_list_head *next)
{
	struct ih_list_head *first = list->next;
	struct ih_list_head *last = list->prev;

	first->prev = prev;
	prev->next = first;

	last->next = next;
	next->prev = last;
}

/**
 * ih_list_splice - join two lists, this is designed for stacks
 * @list: the new list to add.
 * @head: the place to add it in the first list.
 */
static inline void ih_list_splice(const struct ih_list_head *list,
				struct ih_list_head *head)
{
	if (!ih_list_empty(list))
		__ih_list_splice(list, head, head->next);
}

/**
 * ih_list_splice_tail - join two lists, each list being a queue
 * @list: the new list to add.
 * @head: the place to add it in the first list.
 */
static inline void ih_list_splice_tail(struct ih_list_head *list,
				struct ih_list_head *head)
{
	if (!ih_list_empty(list))
		__ih_list_splice(list, head->prev, head);
}

/**
 * ih_list_splice_init - join two lists and reinitialise the emptied list.
 * @list: the new list to add.
 * @head: the place to add it in the first list.
 *
 * The list at @list is reinitialised
 */
static inline void ih_list_splice_init(struct ih_list_head *list,
				    struct ih_list_head *head)
{
	if (!ih_list_empty(list)) {
		__ih_list_splice(list, head, head->next);
		IH_INIT_LIST_HEAD(list);
	}
}

/**
 * ih_list_splice_tail_init - join two lists and reinitialise the emptied list
 * @list: the new list to add.
 * @head: the place to add it in the first list.
 *
 * Each of the lists is a queue.
 * The list at @list is reinitialised
 */
static inline void ih_list_splice_tail_init(struct ih_list_head *list,
					 struct ih_list_head *head)
{
	if (!ih_list_empty(list)) {
		__ih_list_splice(list, head->prev, head);
		IH_INIT_LIST_HEAD(list);
	}
}

/**
 * ih_list_entry - get the struct for this entry
 * @ptr:	the &struct ih_list_head pointer.
 * @type:	the type of the struct this is embedded in.
 * @member:	the name of the list_struct within the struct.
 */
#define ih_list_entry(ptr, type, member) \
	ih_container_of(ptr, type, member)

/**
 * ih_list_first_entry - get the first element from a list
 * @ptr:	the list head to take the element from.
 * @type:	the type of the struct this is embedded in.
 * @member:	the name of the list_struct within the struct.
 *
 * Note, that list is expected to be not empty.
 */
#define ih_list_first_entry(ptr, type, member) \
	ih_list_entry((ptr)->next, type, member)

/**
 * ih_list_for_each	-	iterate over a list
 * @pos:	the &struct ih_list_head to use as a loop cursor.
 * @head:	the head for your list.
 */
#define ih_list_for_each(pos, head) \
	for (pos = (head)->next; pos != (head); \
        	pos = pos->next)

/**
 * __ih_list_for_each	-	iterate over a list
 * @pos:	the &struct ih_list_head to use as a loop cursor.
 * @head:	the head for your list.
 *
 * This variant differs from ih_list_for_each() in that it's the
 * simplest possible list iteration code, no prefetching is done.
 * Use this for code that knows the list to be very short (empty
 * or 1 entry) most of the time.
 */
#define __ih_list_for_each(pos, head) \
	for (pos = (head)->next; pos != (head); pos = pos->next)

/**
 * ih_list_for_each_prev	-	iterate over a list backwards
 * @pos:	the &struct ih_list_head to use as a loop cursor.
 * @head:	the head for your list.
 */
#define ih_list_for_each_prev(pos, head) \
	for (pos = (head)->prev; pos != (head); \
        	pos = pos->prev)

/**
 * ih_list_for_each_safe - iterate over a list safe against removal of list entry
 * @pos:	the &struct ih_list_head to use as a loop cursor.
 * @n:		another &struct ih_list_head to use as temporary storage
 * @head:	the head for your list.
 */
#define ih_list_for_each_safe(pos, n, head) \
	for (pos = (head)->next, n = pos->next; pos != (head); \
		pos = n, n = pos->next)

/**
 * ih_list_for_each_prev_safe - iterate over a list backwards safe against removal of list entry
 * @pos:	the &struct ih_list_head to use as a loop cursor.
 * @n:		another &struct ih_list_head to use as temporary storage
 * @head:	the head for your list.
 */
#define ih_list_for_each_prev_safe(pos, n, head) \
	for (pos = (head)->prev, n = pos->prev; pos != (head); \
	     pos = n, n = pos->prev)

/**
 * ih_list_for_each_entry	-	iterate over list of given type
 * @pos:	the type * to use as a loop cursor.
 * @head:	the head for your list.
 * @member:	the name of the list_struct within the struct.
 */
#define ih_list_for_each_entry(pos, head, member)				\
	for (pos = ih_list_entry((head)->next, typeof(*pos), member);	\
	     &pos->member != (head); 	\
	     pos = ih_list_entry(pos->member.next, typeof(*pos), member))

/**
 * ih_list_for_each_entry_reverse - iterate backwards over list of given type.
 * @pos:	the type * to use as a loop cursor.
 * @head:	the head for your list.
 * @member:	the name of the list_struct within the struct.
 */
#define ih_list_for_each_entry_reverse(pos, head, member)			\
	for (pos = ih_list_entry((head)->prev, typeof(*pos), member);	\
	     &pos->member != (head); 	\
	     pos = ih_list_entry(pos->member.prev, typeof(*pos), member))

/**
 * ih_list_prepare_entry - prepare a pos entry for use in ih_list_for_each_entry_continue()
 * @pos:	the type * to use as a start point
 * @head:	the head of the list
 * @member:	the name of the list_struct within the struct.
 *
 * Prepares a pos entry for use as a start point in ih_list_for_each_entry_continue().
 */
#define ih_list_prepare_entry(pos, head, member) \
	((pos) ? : ih_list_entry(head, typeof(*pos), member))

/**
 * ih_list_for_each_entry_continue - continue iteration over list of given type
 * @pos:	the type * to use as a loop cursor.
 * @head:	the head for your list.
 * @member:	the name of the list_struct within the struct.
 *
 * Continue to iterate over list of given type, continuing after
 * the current position.
 */
#define ih_list_for_each_entry_continue(pos, head, member) 		\
	for (pos = ih_list_entry(pos->member.next, typeof(*pos), member);	\
	     &pos->member != (head);	\
	     pos = ih_list_entry(pos->member.next, typeof(*pos), member))

/**
 * ih_list_for_each_entry_continue_reverse - iterate backwards from the given point
 * @pos:	the type * to use as a loop cursor.
 * @head:	the head for your list.
 * @member:	the name of the list_struct within the struct.
 *
 * Start to iterate over list of given type backwards, continuing after
 * the current position.
 */
#define ih_list_for_each_entry_continue_reverse(pos, head, member)		\
	for (pos = ih_list_entry(pos->member.prev, typeof(*pos), member);	\
	     &pos->member != (head);	\
	     pos = ih_list_entry(pos->member.prev, typeof(*pos), member))

/**
 * ih_list_for_each_entry_from - iterate over list of given type from the current point
 * @pos:	the type * to use as a loop cursor.
 * @head:	the head for your list.
 * @member:	the name of the list_struct within the struct.
 *
 * Iterate over list of given type, continuing from current position.
 */
#define ih_list_for_each_entry_from(pos, head, member) 			\
	for (; &pos->member != (head);	\
	     pos = ih_list_entry(pos->member.next, typeof(*pos), member))

/**
 * ih_list_for_each_entry_safe - iterate over list of given type safe against removal of list entry
 * @pos:	the type * to use as a loop cursor.
 * @n:		another type * to use as temporary storage
 * @head:	the head for your list.
 * @member:	the name of the list_struct within the struct.
 */
#define ih_list_for_each_entry_safe(pos, n, head, member)			\
	for (pos = ih_list_entry((head)->next, typeof(*pos), member),	\
		n = ih_list_entry(pos->member.next, typeof(*pos), member);	\
	     &pos->member != (head); 					\
	     pos = n, n = ih_list_entry(n->member.next, typeof(*n), member))

/**
 * ih_list_for_each_entry_safe_continue
 * @pos:	the type * to use as a loop cursor.
 * @n:		another type * to use as temporary storage
 * @head:	the head for your list.
 * @member:	the name of the list_struct within the struct.
 *
 * Iterate over list of given type, continuing after current point,
 * safe against removal of list entry.
 */
#define ih_list_for_each_entry_safe_continue(pos, n, head, member) 		\
	for (pos = ih_list_entry(pos->member.next, typeof(*pos), member), 		\
		n = ih_list_entry(pos->member.next, typeof(*pos), member);		\
	     &pos->member != (head);						\
	     pos = n, n = ih_list_entry(n->member.next, typeof(*n), member))

/**
 * ih_list_for_each_entry_safe_from
 * @pos:	the type * to use as a loop cursor.
 * @n:		another type * to use as temporary storage
 * @head:	the head for your list.
 * @member:	the name of the list_struct within the struct.
 *
 * Iterate over list of given type from current point, safe against
 * removal of list entry.
 */
#define ih_list_for_each_entry_safe_from(pos, n, head, member) 			\
	for (n = ih_list_entry(pos->member.next, typeof(*pos), member);		\
	     &pos->member != (head);						\
	     pos = n, n = ih_list_entry(n->member.next, typeof(*n), member))

/**
 * ih_list_for_each_entry_safe_reverse
 * @pos:	the type * to use as a loop cursor.
 * @n:		another type * to use as temporary storage
 * @head:	the head for your list.
 * @member:	the name of the list_struct within the struct.
 *
 * Iterate backwards over list of given type, safe against removal
 * of list entry.
 */
#define ih_list_for_each_entry_safe_reverse(pos, n, head, member)		\
	for (pos = ih_list_entry((head)->prev, typeof(*pos), member),	\
		n = ih_list_entry(pos->member.prev, typeof(*pos), member);	\
	     &pos->member != (head); 					\
	     pos = n, n = ih_list_entry(n->member.prev, typeof(*n), member))

/*
 * Double linked lists with a single pointer list head.
 * Mostly useful for hash tables where the two pointer list head is
 * too wasteful.
 * You lose the ability to access the tail in O(1).
 */

struct ih_hlist_head {
	struct ih_hlist_node *first;
};

struct ih_hlist_node {
	struct ih_hlist_node *next, **pprev;
};

#define IH_HLIST_HEAD_INIT { .first = NULL }
#define IH_HLIST_HEAD(name) struct ih_hlist_head name = {  .first = NULL }
#define IH_INIT_HLIST_HEAD(ptr) ((ptr)->first = NULL)
static inline void IH_INIT_HLIST_NODE(struct ih_hlist_node *h)
{
	h->next = NULL;
	h->pprev = NULL;
}

static inline int ih_hlist_unhashed(const struct ih_hlist_node *h)
{
	return !h->pprev;
}

static inline int ih_hlist_empty(const struct ih_hlist_head *h)
{
	return !h->first;
}

static inline void __ih_hlist_del(struct ih_hlist_node *n)
{
	struct ih_hlist_node *next = n->next;
	struct ih_hlist_node **pprev = n->pprev;
	*pprev = next;
	if (next)
		next->pprev = pprev;
}

static inline void ih_hlist_del(struct ih_hlist_node *n)
{
	__ih_hlist_del(n);
	n->next = (struct ih_hlist_node*)IH_LIST_POISON1;
	n->pprev = (struct ih_hlist_node**)IH_LIST_POISON2;
}

static inline void ih_hlist_del_init(struct ih_hlist_node *n)
{
	if (!ih_hlist_unhashed(n)) {
		__ih_hlist_del(n);
		IH_INIT_HLIST_NODE(n);
	}
}

static inline void ih_hlist_add_head(struct ih_hlist_node *n, struct ih_hlist_head *h)
{
	struct ih_hlist_node *first = h->first;
	n->next = first;
	if (first)
		first->pprev = &n->next;
	h->first = n;
	n->pprev = &h->first;
}

static inline void ih_hlist_add_tail(struct ih_hlist_node *n, struct ih_hlist_head *h)
{
	struct ih_hlist_node * node;
	
	if (ih_hlist_empty(h)){
		h->first = n;
		n->pprev = &h->first;
	}else{
		node = h->first;
		while(node->next)
			node = node->next;
		node->next = n;
		n->pprev = &node->next;
	}
}

/* next must be != NULL */
static inline void ih_hlist_add_before(struct ih_hlist_node *n,
					struct ih_hlist_node *next)
{
	n->pprev = next->pprev;
	n->next = next;
	next->pprev = &n->next;
	*(n->pprev) = n;
}

static inline void ih_hlist_add_after(struct ih_hlist_node *n,
					struct ih_hlist_node *next)
{
	next->next = n->next;
	n->next = next;
	next->pprev = &n->next;

	if(next->next)
		next->next->pprev  = &next->next;
}


#define ih_hlist_add_ascending(tpos, pos, n, last_pos, tnew, head, member, sort_num) \
	 if (ih_hlist_empty(head)){\
		(head)->first = &((tnew)->member);\
	 	(tnew)->member.pprev = &((head)->first);\
	 }else{\
		ih_hlist_for_each_entry_safe(tpos, pos, n, head, member){\
			last_pos = pos;\
			if ((tpos->sort_num) < ((tnew)->sort_num))\
				continue;\
			break;\
		}\
		if (pos){\
			*(pos->pprev) = &((tnew)->member);\
			(tnew)->member.pprev = pos->pprev;\
			(tnew)->member.next = pos;\
			pos->pprev = &((tnew)->member.next);\
		}else{\
			(last_pos)->next = &((tnew)->member);\
			(tnew)->member.pprev = &((last_pos)->next);\
		}\
	 }

#define ih_hlist_add_descending(tpos, pos, n, last_pos, tnew, head, member, sort_num) \
	 if (ih_hlist_empty(head)){\
		(head)->first = &((tnew)->member);\
	 	(tnew)->member.pprev = &((head)->first);\
	 }else{\
		ih_hlist_for_each_entry_safe(tpos, pos, n, head, member){\
			last_pos = pos;\
			if ((tpos->sort_num) > ((tnew)->sort_num))\
				continue;\
			break;\
		}\
		if (pos){\
			*(pos->pprev) = &((tnew)->member);\
			(tnew)->member.pprev = pos->pprev;\
			(tnew)->member.next = pos;\
			pos->pprev = &((tnew)->member.next);\
		}else{\
			(last_pos)->next = &((tnew)->member);\
			(tnew)->member.pprev = &((last_pos)->next);\
		}\
	 }

/*
 * Move a list from one list head to another. Fixup the pprev
 * reference of the first entry if it exists.
 */
static inline void ih_hlist_move_list(struct ih_hlist_head *old,
				   struct ih_hlist_head *new_l)
{
	new_l->first = old->first;
	if (new_l->first)
		new_l->first->pprev = &new_l->first;
	old->first = NULL;
}

#define ih_hlist_entry(ptr, type, member) ih_container_of(ptr,type,member)

#define ih_hlist_for_each(pos, head) \
	for (pos = (head)->first; pos; \
	     pos = pos->next)

#define ih_hlist_for_each_safe(pos, n, head) \
	for (pos = (head)->first; pos && ({ n = pos->next; 1; }); \
	     pos = n)

/**
 * ih_hlist_for_each_entry	- iterate over list of given type
 * @tpos:	the type * to use as a loop cursor.
 * @pos:	the &struct ih_hlist_node to use as a loop cursor.
 * @head:	the head for your list.
 * @member:	the name of the ih_hlist_node within the struct.
 */
#define ih_hlist_for_each_entry(tpos, pos, head, member)			 \
	for (pos = (head)->first;					 \
	     pos &&			 \
		({ tpos = ih_hlist_entry(pos, typeof(*tpos), member); 1;}); \
	     pos = pos->next)

/**
 * ih_hlist_for_each_entry_continue - iterate over a hlist continuing after current point
 * @tpos:	the type * to use as a loop cursor.
 * @pos:	the &struct ih_hlist_node to use as a loop cursor.
 * @member:	the name of the ih_hlist_node within the struct.
 */
#define ih_hlist_for_each_entry_continue(tpos, pos, member)		 \
	for (pos = (pos)->next;						 \
	     pos &&			 \
		({ tpos = ih_hlist_entry(pos, typeof(*tpos), member); 1;}); \
	     pos = pos->next)

/**
 * ih_hlist_for_each_entry_from - iterate over a hlist continuing from current point
 * @tpos:	the type * to use as a loop cursor.
 * @pos:	the &struct ih_hlist_node to use as a loop cursor.
 * @member:	the name of the ih_hlist_node within the struct.
 */
#define ih_hlist_for_each_entry_from(tpos, pos, member)			 \
	for (; pos &&			 \
		({ tpos = ih_hlist_entry(pos, typeof(*tpos), member); 1;}); \
	     pos = pos->next)

/**
 * ih_hlist_for_each_entry_safe - iterate over list of given type safe against removal of list entry
 * @tpos:	the type * to use as a loop cursor.
 * @pos:	the &struct ih_hlist_node to use as a loop cursor.
 * @n:		another &struct ih_hlist_node to use as temporary storage
 * @head:	the head for your list.
 * @member:	the name of the ih_hlist_node within the struct.
 */
#define ih_hlist_for_each_entry_safe(tpos, pos, n, head, member) 		 \
	for (pos = (head)->first;					 \
	     pos && ({ n = pos->next; 1; }) && 				 \
		({ tpos = ih_hlist_entry(pos, typeof(*tpos), member); 1;}); \
	     pos = n)

#endif
