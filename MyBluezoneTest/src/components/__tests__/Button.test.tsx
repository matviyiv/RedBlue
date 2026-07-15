import React from 'react';
import {Text} from 'react-native';
import renderer, {ReactTestRenderer, act} from 'react-test-renderer';
import {Button} from '../Button';

describe('Button', () => {
  it('hello', () => {
    let tree: ReactTestRenderer;
    act(() => {
      tree = renderer.create(<Button title="hello" onPress={() => {}} />);
    });

    const textNode = tree!.root.findByType(Text);
    expect(textNode.props.children).toBe('hello');
  });
});
